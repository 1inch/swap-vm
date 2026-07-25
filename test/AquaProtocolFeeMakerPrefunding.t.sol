// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { stdError } from "forge-std/Test.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";

/// @notice Protocol-fee-on-amountIn settles the fee from the maker's own tokenIn inventory while the
///         program runs, i.e. before SwapVM credits the taker's tokenIn to the maker. These tests pin
///         down the consequences: a position with no tokenIn inventory cannot trade at all, and a
///         position with a thin tokenIn side can only trade up to `balanceIn * BPS / feeBps`.
contract AquaProtocolFeeMakerPrefundingTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    /// @dev 1% in the 1e9 scale used by the fee instructions
    uint32 internal constant PROTOCOL_FEE_BPS = 0.01e9;

    /// @dev Kirill's example from the report: a position left with dust on the tokenIn side
    uint256 internal constant THIN_BALANCE_IN = 0.01e18;
    uint256 internal constant DEEP_BALANCE_OUT = 20_000_000e18;

    /// @dev Largest amountIn whose fee still fits into THIN_BALANCE_IN
    uint256 internal constant MAX_TRADABLE_IN = THIN_BALANCE_IN * BPS / PROTOCOL_FEE_BPS;

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

    /// @notice A position holding only tokenB sits at the top of its price range and sells tokenB for
    ///         tokenA. It never holds tokenA, so the fee pull underflows the maker's Aqua balance.
    function test_SingleSidedPosition_QuoteSucceeds_SwapReverts() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.AquaProtocolFeeAmountIn));
        shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        assertEq(quotedIn, 10e18, "quote prices the swap");
        assertGt(quotedOut, 0, "quote returns a non-zero output");

        vm.expectRevert(stdError.arithmeticError);
        swap(swapProgram, order);
    }

    /// @notice Same position, same failure through the dynamic fee provider variant.
    function test_SingleSidedPosition_DynamicFee_SwapReverts() public {
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

        vm.expectRevert(stdError.arithmeticError);
        swap(swapProgram, order);
    }

    /// @notice A two-sided position with a thin tokenIn side trades fine right up to the point where the
    ///         fee exceeds that side's balance.
    function test_ThinTokenInSide_TradesUpToBalanceOverFeeRate() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);

        SwapProgram memory swapProgram = _swapProgram(MAX_TRADABLE_IN);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(amountIn, MAX_TRADABLE_IN, "taker pays the full amountIn");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), THIN_BALANCE_IN, "fee drains the whole tokenIn side");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, MAX_TRADABLE_IN, "pool keeps amountIn net of the fee it had pre-funded");
    }

    /// @notice One wei of fee more than the tokenIn side holds and the swap is dead.
    function test_ThinTokenInSide_LargerTradeReverts() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);

        SwapProgram memory swapProgram = _swapProgram(MAX_TRADABLE_IN + 0.1e18);
        mintTokenInToTaker(swapProgram);

        (, uint256 quotedOut) = quote(swapProgram, order);
        assertGt(quotedOut, 0, "quote still prices a trade the pool cannot settle");

        vm.expectRevert(stdError.arithmeticError);
        swap(swapProgram, order);
    }

    /// @notice The non-Aqua fee opcode charges the maker's wallet instead of the strategy ledger, so a
    ///         single-sided position can pay it out of a working buffer. This is the only mitigation that
    ///         needs no new router deployment, at the cost of the ledger over-stating the pool by the
    ///         accumulated fees.
    function test_SingleSidedPosition_WalletFeeOpcode_Succeeds() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        // Working buffer the fee is charged against, plus the router allowance the opcode spends
        tokenA.mint(maker, 1e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        uint256 expectedFee = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertEq(tokenA.balanceOf(protocolFeeRecipient), expectedFee, "recipient is paid from the maker's wallet");
        assertEq(tokenA.balanceOf(maker), 1e18 - expectedFee + amountIn, "wallet funds the fee and receives amountIn");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "ledger credits the full amountIn and now over-states the wallet by the fee");
    }
}
