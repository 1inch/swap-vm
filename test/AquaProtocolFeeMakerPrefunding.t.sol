// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";

/// @notice Protocol-fee-on-amountIn is charged against the maker's own tokenIn inventory while the program
///         runs, before SwapVM credits the taker's tokenIn. A maker that is short of tokenIn no longer
///         blocks the swap: the fee is skipped and reported. These tests cover what that costs — pricing
///         still charges the taker for the fee, so a skipped fee lands in the maker's pool instead.
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
        return _concentratedProgram(feeOpcode, 0);
    }

    function _concentratedProgram(Opcode feeOpcode, uint256 salt) internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(feeOpcode, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX)),
            p.build(Opcode.Salt, abi.encodePacked(salt))
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
    ///         tokenA. It never holds tokenA, so the fee is skipped on every single swap it ever serves.
    function test_SingleSidedPosition_SwapSucceeds_FeeSkipped() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.AquaProtocolFeeAmountIn));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(amountIn, 10e18, "taker pays the full fee-inclusive amountIn");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "the whole amountIn lands in the pool, fee included");
    }

    /// @notice Runs the same trade against two identical positions, one where the fee is collectible and
    ///         one where it is not. The taker gets the same output either way, so a skipped fee is not a
    ///         discount for the taker — it is income for the maker.
    function test_SkippedFeeIsCapturedByTheMaker() public {
        SwapProgram memory swapProgram = _swapProgram(10e18);

        // The wallet-charging opcode leaves the Aqua ledger untouched, so both positions price identically
        // and the only variable is whether the maker granted the allowance the fee needs.
        ISwapVM.Order memory skipped = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn, 1));
        shipStrategy(skipped, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);
        mintTokenInToTaker(swapProgram);

        uint256 makerBefore = tokenA.balanceOf(maker);
        (uint256 amountIn, uint256 skippedOut) = swap(swapProgram, skipped);
        uint256 makerGainWhenSkipped = tokenA.balanceOf(maker) - makerBefore;
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "no allowance, no fee");

        ISwapVM.Order memory collected = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn, 2));
        shipStrategy(collected, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        mintTokenInToTaker(swapProgram);

        makerBefore = tokenA.balanceOf(maker);
        (, uint256 collectedOut) = swap(swapProgram, collected);
        uint256 makerGainWhenCollected = tokenA.balanceOf(maker) - makerBefore;

        uint256 feePaid = tokenA.balanceOf(protocolFeeRecipient);
        assertEq(feePaid, amountIn * PROTOCOL_FEE_BPS / BPS, "the collectible position pays 1% of amountIn");
        assertEq(skippedOut, collectedOut, "the taker is charged for the fee either way");
        assertEq(makerGainWhenSkipped - makerGainWhenCollected, feePaid, "the maker keeps what the recipient lost");
    }

    /// @notice Trades above `balanceIn * BPS / feeBps` now go through, paying no fee at all.
    function test_ThinTokenInSide_LargeTradeSkipsTheWholeFee() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN + 0.1e18);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        uint256 chargedToTaker = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertGt(chargedToTaker, THIN_BALANCE_IN, "the fee is larger than the tokenIn side of the position");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "no partial collection, the whole fee is dropped");
    }

    /// @notice Below the ceiling nothing changes: the fee is still collected in full.
    function test_ThinTokenInSide_SmallTradeStillPaysTheFee() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);
        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "fee is collected");
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

    /// @notice The wallet-charging variant skips on a missing allowance, which is the maker's own setting.
    function test_WalletFeeOpcode_SkipsWithoutApproval() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn));
        shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);
        tokenA.mint(maker, 1e18);

        SwapProgram memory swapProgram = _swapProgram(10e18);
        mintTokenInToTaker(swapProgram);

        swap(swapProgram, order);
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "no router allowance means no fee");
    }
}
