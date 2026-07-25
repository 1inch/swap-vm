// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";

/// @notice The Aqua protocol fee on amountIn is charged against the maker's own tokenIn balance while the
///         program runs, before SwapVM credits the taker's tokenIn. A maker that is short of tokenIn no
///         longer blocks the swap: the fee is skipped and reported. These tests cover both what that
///         unblocks and what it costs.
contract AquaProtocolFeeMakerPrefundingTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    /// @dev 1% in the 1e9 scale used by the fee instructions
    uint32 internal constant PROTOCOL_FEE_BPS = 0.01e9;

    /// @dev Kirill's example from the report: a position left with dust on the tokenIn side
    uint256 internal constant THIN_BALANCE_IN = 0.01e18;
    uint256 internal constant DEEP_BALANCE_OUT = 20_000_000e18;

    /// @dev Largest amountIn whose fee still fits into THIN_BALANCE_IN
    uint256 internal constant MAX_PAYABLE_IN = THIN_BALANCE_IN * BPS / PROTOCOL_FEE_BPS;

    /// @dev Concentrated range of [1.0, 4.0] tokenB per tokenA, expressed as sqrt prices in 1e18
    uint256 internal constant SQRT_PRICE_MIN = 1e18;
    uint256 internal constant SQRT_PRICE_MAX = 2e18;

    ProtocolFeeProviderMock public feeProvider;

    function setUp() public virtual override {
        super.setUp();
        feeProvider = new ProtocolFeeProviderMock(PROTOCOL_FEE_BPS, protocolFeeRecipient, address(this));
    }

    function _concentratedProgram(Opcode feeOpcode) internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(feeOpcode, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );
    }

    function _xycProgram() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCSwap)
        );
    }

    function _swapProgram(uint256 amount) internal view returns (SwapProgram memory) {
        return SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: true,
            isExactIn: true
        });
    }

    /// @dev Ships a thin two-sided XYC position and funds the maker's wallet to match the ledger
    function _shipThinPosition(ISwapVM.Order memory order) internal returns (bytes32 strategyHash) {
        strategyHash = shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);
    }

    /// @notice A position holding only tokenB sits at the top of its price range and sells tokenB for
    ///         tokenA. It never holds tokenA, so it used to revert on every swap and now goes through.
    function test_SingleSidedPosition_SwapSucceeds_FeeSkipped() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.AquaProtocolFeeAmountIn));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);

        vm.expectEmit(address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, quotedIn * PROTOCOL_FEE_BPS / BPS);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(amountIn, quotedIn, "swap consumes the quoted amountIn");
        assertEq(amountOut, quotedOut, "swap delivers the quoted amountOut");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "the whole amountIn lands in the pool, fee included");
    }

    /// @notice Pricing does not change when the fee is skipped, so the taker still pays for it. Checks the
    ///         output against the curve applied to amountIn net of the fee, then shows the pool keeping the
    ///         difference the recipient did not get.
    function test_SkippedFeeIsCapturedByTheMaker() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        bytes32 strategyHash = _shipThinPosition(order);

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN + 0.1e18);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        uint256 fee = amountIn * PROTOCOL_FEE_BPS / BPS;
        uint256 netAmountIn = amountIn - fee;
        uint256 pricedOut = netAmountIn * DEEP_BALANCE_OUT / (THIN_BALANCE_IN + netAmountIn);

        assertGt(fee, THIN_BALANCE_IN, "the fee is larger than the tokenIn side of the position");
        assertEq(amountOut, pricedOut, "the taker is priced as if the fee had been taken");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "no partial collection, the whole fee is dropped");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, THIN_BALANCE_IN + amountIn, "the pool keeps the fee the recipient did not get");
    }

    /// @notice Below the ceiling nothing changes: the fee is still collected in full.
    function test_ThinTokenInSide_SmallTradeStillPaysTheFee() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        bytes32 strategyHash = _shipThinPosition(order);

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "fee is collected");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "pool keeps amountIn net of the fee it had pre-funded");
    }

    /// @notice The dynamic provider variant behaves the same way.
    function test_SingleSidedPosition_DynamicFeeSkipped() public {
        Program p;
        bytes memory program = bytes.concat(
            p.build(Opcode.AquaDynamicProtocolFeeAmountIn, FeeArgsBuilder.buildDynamicProtocolFee(address(feeProvider))),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );

        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        swap(swapProgram, order);
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "dynamic fee is skipped too");
    }

    /// @notice Only the Aqua variants gained a skip path. The wallet-charging opcode still reverts, so an
    ///         Aqua strategy built on it stays blocked until the maker funds and approves tokenIn.
    function test_WalletFeeOpcode_StillReverts() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn));
        shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swap(swapProgram, order);
    }
}
