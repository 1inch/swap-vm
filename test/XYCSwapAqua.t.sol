// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS } from "../src/instructions/Fee.sol";
import { ContextLib } from "../src/libs/VM.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";

import { console } from "forge-std/console.sol";

contract XYCSwapAquaTest is AquaSwapVMTest {
    using Math for uint256;

    function setUp() public virtual override {
        super.setUp();
    }

    function _makerSetup(
        uint256 balanceA,
        uint256 balanceB
    ) internal pure returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: balanceA,
            balanceB: balanceB,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: 0,
            feeInBps: 0,
            feeOutBps: 0,
            progressiveFeeBps: 0,
            protocolFeeRecipient: address(0),
            swapType: SwapType.XYC
        });
    }

    function _makerSetup() internal pure returns (MakerSetup memory) {
        return _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_B);
    }

    function _swapProgram(
        uint256 amount,
        bool zeroForOne,
        bool isExactIn
    ) internal view returns (SwapProgram memory) {
        return SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: zeroForOne,
            isExactIn: isExactIn
        });
    }

    // ============================================
    // Balance Consistency Tests
    // Verifies that token balances are correctly updated after swaps
    // and that no tokens are created or destroyed during operations
    // ============================================

    function test_Aqua_XYC_ExactIn_BalancesCorrect() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 amountOutExpected = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_XYC_ExactOut_BalancesCorrect() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap tokenB for 100 tokenA

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram, 225e18);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 amountInExpected = setup.balanceA * amountOut / (setup.balanceB - amountOut);
        assertApproxEqAbs(takerBalanceABefore - takerBalanceAAfter, amountInExpected, 1, "Taker paid correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    // ============================================
    // Arbitrage Protection Tests
    // Ensures that round-trip swaps (A→B→A) always result in a loss
    // preventing profitable arbitrage cycles due to rounding
    // Tests cover all combinations of exactIn and exactOut swaps
    // ============================================

    function test_Aqua_XYC_NoArbitrage_InThenOut() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgramIn = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB, exactIn
        SwapProgram memory swapProgramOut = _swapProgram(0, false, false); // Swap tokenA for tokenB, exactOut

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgramIn);
        mintTokenOutToMaker(swapProgramIn, 200e18);

        (uint256 balanceATakerBefore, uint256 balanceBTakerBefore) = getTakerBalances(swapProgramIn.taker);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgramIn, order);

        // Due to ceiling division in XYC, exactOut swap require more amountIn by 1 wei than exactIn swap provided
        mintTokenInToTaker(swapProgramOut, 1);
        mintTokenOutToMaker(swapProgramOut, amountOut);
        swapProgramOut.amount = amountIn; // Set exact out amount
        swap(swapProgramOut, order);

        // Strategy balances should be not less than before the swaps
        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertGe(balanceAAfter, balanceABefore, "Strategy balance A should not decrease after swaps");
        assertGe(balanceBAfter, balanceBBefore, "Strategy balance B should not decrease after swaps");

        // Taker should pay more or the same amount in due to rounding in XYC (ceiling)
        // We added 1 wei to cover the ceiling division case so the taker should at best break even
        (uint256 balanceATakerAfter, uint256 balanceBTakerAfter) = getTakerBalances(swapProgramIn.taker);
        assertEq(balanceATakerBefore, balanceATakerAfter, "Taker balance A should be consistent after round-trip swap");
        assertEq(balanceBTakerBefore, balanceBTakerAfter, "Taker balance B should be consistent after round-trip swap");
    }

    function test_Aqua_XYC_NoArbitrage_OutThenIn() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgramOut = _swapProgram(100e18, true, false); // Swap 100 tokenB for tokenA, exactOut
        SwapProgram memory swapProgramIn = _swapProgram(100e18, false, true); // Swap tokenA for tokenB, exactIn

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgramOut);
        (uint256 balanceATakerBefore, uint256 balanceBTakerBefore) = getTakerBalances(swapProgramOut.taker);

        mintTokenOutToMaker(swapProgramOut, 200e18);
        (uint256 amountIn,) = swap(swapProgramOut, order);

        mintTokenOutToMaker(swapProgramIn, amountIn);
        swap(swapProgramIn, order);

        // Strategy balances should be not less than before the swaps
        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertGe(balanceAAfter, balanceABefore, "Strategy balance A should not decrease after swaps");
        assertGe(balanceBAfter, balanceBBefore, "Strategy balance B should not decrease after swaps");

        // Taker should get less or the same amount out due to rounding in XYC (floor)
        (uint256 balanceATakerAfter, uint256 balanceBTakerAfter) = getTakerBalances(swapProgramOut.taker);
        assertGe(balanceATakerBefore, balanceATakerAfter, "Taker should get less or the same amount out due to rounding");
        assertEq(balanceBTakerBefore, balanceBTakerAfter, "Taker balance B should be consistent after round-trip swap");
    }

    function test_Aqua_XYC_NoArbitrage_InThenIn() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB, exactIn

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 balanceATakerBefore, uint256 balanceBTakerBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        swapProgram.zeroForOne = false; // Reverse direction
        swapProgram.amount = amountOut; // Set exact in amount
        mintTokenOutToMaker(swapProgram, amountIn);
        swap(swapProgram, order);

        // Strategy balances should be not less than before the swaps
        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertGe(balanceAAfter, balanceABefore, "Strategy balance A should not decrease after swaps");
        assertGe(balanceBAfter, balanceBBefore, "Strategy balance B should not decrease after swaps");

        // Taker should get less or the same amount out due to rounding in XYC (floor)
        (uint256 balanceATakerAfter, uint256 balanceBTakerAfter) = getTakerBalances(swapProgram.taker);
        assertGe(balanceATakerBefore, balanceATakerAfter, "Taker should get less or the same amount out due to rounding");
        assertEq(balanceBTakerBefore, balanceBTakerAfter, "Taker balance B should be consistent after round-trip swap");
    }

    function test_Aqua_XYC_NoArbitrage_OutThenOut() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap 100 tokenA for tokenB, exactOut

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 balanceATakerBefore, uint256 balanceBTakerBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn,) = swap(swapProgram, order);

        swapProgram.zeroForOne = false; // Reverse direction
        swapProgram.amount = amountIn; // Set exact in amount
        mintTokenOutToMaker(swapProgram, amountIn);
        mintTokenInToTaker(swapProgram, 1); // Add 1 wei to cover ceiling division case
        swap(swapProgram, order);

        // Strategy balances should be not less than before the swaps
        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertGe(balanceAAfter, balanceABefore, "Strategy balance A should not decrease after swaps");
        assertGe(balanceBAfter, balanceBBefore, "Strategy balance B should not decrease after swaps");

        // Taker should get less or the same amount out due to rounding in XYC (ceiling)
        // We added 1 wei to cover the ceiling division case so the taker should at best break even
        (uint256 balanceATakerAfter, uint256 balanceBTakerAfter) = getTakerBalances(swapProgram.taker);
        assertEq(balanceATakerBefore, balanceATakerAfter, "Taker should get less or the same amount out due to rounding");
        assertEq(balanceBTakerBefore, balanceBTakerAfter, "Taker balance B should be consistent after round-trip swap");
    }

    // ============================================
    // Constant Product (K) Invariant Tests
    // Verifies that K = balanceA × balanceB never decreases after swaps
    // Tests with various amounts: dust (1 wei), normal, and maximum values
    // ============================================

    // Invariant should never decrease: this test is important because XYC uses floor/ceiling division which can lead to loss of precision
    function _checkInvariantNeverDecreases(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amountIn,
        bool isExactIn,
        bool shouldRevert
    ) internal returns (uint256 invariantBefore, uint256 invariantAfter) {
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(amountIn, true, isExactIn);

        invariantBefore = setup.balanceA * setup.balanceB;

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);
        if (shouldRevert) {
            // Expect revert because amountIn/amountOut equal zero due to dust trade
            // e.g. trying to swap 1 unit when balances are in millions
            if (isExactIn) {
                vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
            } else {
                vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
            }
            swap(swapProgram, order);
            return (invariantBefore, invariantBefore); // Return same invariant on revert
        }

        swap(swapProgram, order);

        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        invariantAfter = balanceAAfter * balanceBAfter;
    }

    function test_Aqua_XYC_Dust_ExactIn_KInvariant() public {
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            INITIAL_BALANCE_A, INITIAL_BALANCE_B, DUST_AMOUNT, true, false);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for dust amount exact in");
    }

    function test_Aqua_XYC_Dust_ExactOut_KInvariant() public {
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            INITIAL_BALANCE_A, INITIAL_BALANCE_B, DUST_AMOUNT, false, false);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for dust amount exact out");
    }

    function test_Aqua_XYC_Dust_ExactIn_KInvariant_Balanced() public {
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            INITIAL_BALANCE_A, INITIAL_BALANCE_A, DUST_AMOUNT, true, true);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for dust amount exact in balanced");
    }

    function test_Aqua_XYC_Dust_ExactOut_KInvariant_Balanced() public {
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            INITIAL_BALANCE_A, INITIAL_BALANCE_A, DUST_AMOUNT, false, false);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for dust amount exact out balanced");
    }

    function test_Aqua_XYC_MaxAmount_ExactIn_KInvariant() public {
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            MAX_REASONABLE_BALANCE, MAX_REASONABLE_BALANCE, MAX_REASONABLE_AMOUNT, true, false);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for max reasonable amount exact in");
    }

    function test_Aqua_XYC_MaxAmount_ExactOut_KInvariant() public {
        // MAX_REASONABLE_AMOUNT >> 8 is used to test the edge case because Aqua supports only uint248 max amount
        (uint256 invariantBefore, uint256 invariantAfter) = _checkInvariantNeverDecreases(
            MAX_REASONABLE_BALANCE, MAX_REASONABLE_BALANCE, MAX_REASONABLE_AMOUNT >> 8, false, false);
        assertGe(invariantAfter, invariantBefore, "Invariant should not decrease for max reasonable amount exact out");
    }

    // ============================================
    // Swap Rate vs Spot Price Tests
    // Confirms that effective swap rate is always worse than or equal to spot price
    // due to price impact, protecting LPs from unfavorable trades
    // ============================================

    function _checkSwapRateAlwaysWorseOrEqualToSpotPrice(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amountIn,
        bool isExactIn
    ) internal returns (uint256 spotPrice, uint256 effectivePrice) {
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(amountIn, true, isExactIn);

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountInAfter, uint256 amountOutAfter) = swap(swapProgram, order);
        spotPrice = (balanceB * ONE) / balanceA;
        effectivePrice = (amountOutAfter * ONE) / amountInAfter;
    }

    function test_Aqua_XYC_Dust_ExactIn_SwapRateVsSpot() public {
        (uint256 spotPrice, uint256 effectivePrice) = _checkSwapRateAlwaysWorseOrEqualToSpotPrice(
            INITIAL_BALANCE_A, INITIAL_BALANCE_B, DUST_AMOUNT, true);
        assertGe(spotPrice, effectivePrice, "Effective price should be worse or equal to spot price for exact in");
    }

    function test_Aqua_XYC_Dust_ExactOut_SwapRateVsSpot() public {
        (uint256 spotPrice, uint256 effectivePrice) = _checkSwapRateAlwaysWorseOrEqualToSpotPrice(
            INITIAL_BALANCE_A, INITIAL_BALANCE_B, DUST_AMOUNT, false);
        assertGe(spotPrice, effectivePrice, "Effective price should be worse or equal to spot price for exact out");
    }

    function test_Aqua_XYC_MaxAmount_ExactIn_SwapRateVsSpot() public {
        (uint256 spotPrice, uint256 effectivePrice) = _checkSwapRateAlwaysWorseOrEqualToSpotPrice(
            MAX_REASONABLE_BALANCE, MAX_REASONABLE_BALANCE, MAX_REASONABLE_AMOUNT, true);
        assertGe(spotPrice, effectivePrice, "Effective price should be worse or equal to spot price for exact in max reasonable amount");
    }

    function test_Aqua_XYC_MaxAmount_ExactOut_SwapRateVsSpot() public {
        // MAX_REASONABLE_AMOUNT >> 8 is used to test the edge case because Aqua supports only uint248 max amount
        (uint256 spotPrice, uint256 effectivePrice) = _checkSwapRateAlwaysWorseOrEqualToSpotPrice(
            MAX_REASONABLE_BALANCE, MAX_REASONABLE_BALANCE, MAX_REASONABLE_AMOUNT >> 8, false);
        assertGe(spotPrice, effectivePrice, "Effective price should be worse or equal to spot price for exact out max reasonable amount");
    }

    // ============================================
    // Economic Properties Tests
    // Validates key economic behaviors: rounding favors protocol,
    // single swaps beat multiple splits, and price impact increases with size
    // ============================================

    function test_Aqua_XYC_RoundingFavorsProtocol() public {
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_A); // 1:1 price
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(DUST_AMOUNT, true, true); // Swap 1 tokenA for tokenB

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swap(swapProgram, order); // Expect revert due to dust trade and flooring to 0

        swapProgram.isExactIn = false; // Change to exact out
        (uint256 amountIn,) = swap(swapProgram, order); // Should succeed
        assertGe(amountIn, swapProgram.amount, "Rounding should favor strategy on exact out swap");
    }

    function test_Aqua_XYC_ExactIn_SingleBeatsSplit() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);

        uint256 totalAmountIn = 100e18;
        uint256 splitCount = 4;
        uint256 splitAmountIn = totalAmountIn / splitCount;

        SwapProgram memory swapProgram = _swapProgram(totalAmountIn, true, true);

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        uint256 cumulativeAmountOut = 0;
        for (uint256 i = 0; i < splitCount; i++) {
            swapProgram.amount = splitAmountIn;
            ( , uint256 amountOut) = swap(swapProgram, strategy);
            cumulativeAmountOut += amountOut;
        }

        // Single swap for total amount
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = totalAmountIn;

        ( , uint256 singleAmountOut) = swap(swapProgram, strategy);
        assertGe(singleAmountOut, cumulativeAmountOut, "Single swap should yield equal or more amount out than split swaps");
    }

    function test_Aqua_XYC_ExactOut_SingleBeatsSplit() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);

        uint256 totalAmountOut = 100e18;
        uint256 splitCount = 4;
        uint256 splitAmountOut = totalAmountOut / splitCount;

        SwapProgram memory swapProgram = _swapProgram(totalAmountOut, true, false);

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        uint256 cumulativeAmountIn = 0;
        for (uint256 i = 0; i < splitCount; i++) {
            swapProgram.amount = splitAmountOut;
            (uint256 amountIn, ) = swap(swapProgram, strategy);
            cumulativeAmountIn += amountIn;
        }

        // Single swap for total amount
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = totalAmountOut;

        (uint256 singleAmountIn, ) = swap(swapProgram, strategy);
        assertLe(singleAmountIn, cumulativeAmountIn, "Single swap should require equal or less amount in than split swaps");
    }

    function test_Aqua_XYC_ExactIn_PriceImpactGrows() public {
        MakerSetup memory setup = _makerSetup();

        uint256 smallSwapAmountIn = SMALL_AMOUNT;
        uint256 mediumSwapAmountIn = MEDIUM_AMOUNT;
        uint256 largeSwapAmountIn = LARGE_AMOUNT;

        SwapProgram memory swapProgram = _swapProgram(smallSwapAmountIn, true, true);

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // isolate small swap
        ISwapVM.Order memory strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        ( , uint256 smallAmountOut) = swap(swapProgram, strategy);
        uint256 smallEffectivePrice = (smallAmountOut * ONE) / smallSwapAmountIn;

        // isolate medium swap
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = mediumSwapAmountIn;
        ( , uint256 mediumAmountOut) = swap(swapProgram, strategy);
        uint256 mediumEffectivePrice = (mediumAmountOut * ONE) / mediumSwapAmountIn;

        // isolate large swap
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = largeSwapAmountIn;
        ( , uint256 largeAmountOut) = swap(swapProgram, strategy);
        uint256 largeEffectivePrice = (largeAmountOut * ONE) / largeSwapAmountIn;

        assertLt(largeEffectivePrice, smallEffectivePrice, "Larger swap should have worse effective price due to price impact");
        assertLt(mediumEffectivePrice, smallEffectivePrice, "Medium swap should have worse effective price than small swap due to price impact");
        assertLt(largeEffectivePrice, mediumEffectivePrice, "Large swap should have worse effective price than medium swap due to price impact");
    }

    function test_Aqua_XYC_ExactOut_PriceImpactGrows() public {
        MakerSetup memory setup = _makerSetup();

        uint256 smallSwapAmountOut = SMALL_AMOUNT;
        uint256 mediumSwapAmountOut = MEDIUM_AMOUNT;
        uint256 largeSwapAmountOut = LARGE_AMOUNT;

        SwapProgram memory swapProgram = _swapProgram(smallSwapAmountOut, true, false);

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // isolate small swap
        ISwapVM.Order memory strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        (uint256 smallAmountIn, ) = swap(swapProgram, strategy);
        uint256 smallEffectivePrice = (smallSwapAmountOut * ONE) / smallAmountIn;

        // isolate medium swap
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = mediumSwapAmountOut;
        (uint256 mediumAmountIn, ) = swap(swapProgram, strategy);
        uint256 mediumEffectivePrice = (mediumSwapAmountOut * ONE) / mediumAmountIn;

        // isolate large swap
        strategy = createStrategy(setup);
        shipStrategy(strategy, tokenA, tokenB, setup.balanceA, setup.balanceB);
        swapProgram.amount = largeSwapAmountOut;
        (uint256 largeAmountIn, ) = swap(swapProgram, strategy);
        uint256 largeEffectivePrice = (largeSwapAmountOut * ONE) / largeAmountIn;

        assertLe(largeEffectivePrice, smallEffectivePrice, "Larger swap should have worse effective price due to price impact");
        assertLe(mediumEffectivePrice, smallEffectivePrice, "Medium swap should have worse effective price than small swap due to price impact");
        assertLe(largeEffectivePrice, mediumEffectivePrice, "Large swap should have worse effective price than medium swap due to price impact");
    }

    // ============================================
    // Rounding Error Accumulation Tests
    // Ensures that multiple small swaps cannot accumulate rounding errors
    // to drain the pool or create value from nothing
    // ============================================

    function test_Aqua_XYC_ExactIn_NoRoundingAccumulation() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(DUST_AMOUNT, true, true); // Swap 1 tokenA for tokenB

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        uint256 iterations = 1000;
        for (uint256 i = 0; i < iterations; i++) {
            (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
            assertGt(amountIn, 0, "Amount in should be greater than zero");
            assertGt(amountOut, 0, "Amount out should be greater than zero");
        }

        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertEq(balanceAAfter - balanceABefore, iterations * DUST_AMOUNT, "Total amount in should equal iterations times dust amount");
        assertGt(balanceBBefore - balanceBAfter, 0, "Total amount out should be greater than zero");
    }

    function test_Aqua_XYC_ExactOut_NoRoundingAccumulation() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(DUST_AMOUNT, true, false); // Swap tokenB for 1 tokenA

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 balanceABefore, uint256 balanceBBefore) = getAquaBalances(strategyHash);

        uint256 iterations = 1000;
        for (uint256 i = 0; i < iterations; i++) {
            (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
            assertGt(amountIn, 0, "Amount in should be greater than zero");
            assertEq(amountOut, DUST_AMOUNT, "Amount out should equal dust amount");
        }

        (uint256 balanceAAfter, uint256 balanceBAfter) = getAquaBalances(strategyHash);
        assertGt(balanceAAfter - balanceABefore, 0, "Total amount out should be greater than zero");
        assertEq(balanceBBefore - balanceBAfter, iterations * DUST_AMOUNT, "Total amount in should equal iterations times dust amount");
    }

    // ============================================
    // Overflow Protection Tests
    // Verifies that arithmetic operations revert gracefully
    // when dealing with values that would cause uint256 overflow
    // ============================================

    function test_Aqua_XYC_ExactIn_OverflowReverts() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(OVERFLOW_AMOUNT, true, true); // Swap max uint256 tokenA for tokenB

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        vm.expectRevert(); // reverts with panic: arithmetic underflow or overflow (0x11)
        swap(swapProgram, order);
    }

    function test_Aqua_XYC_ExactOut_OverflowReverts() public {
        MakerSetup memory setup = _makerSetup();
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(OVERFLOW_AMOUNT, true, false); // Swap tokenB for max uint256 tokenA

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        vm.expectRevert(); // reverts with panic: arithmetic underflow or overflow (0x11)
        swap(swapProgram, order);
    }

    // ============================================
    // Minimal Amounts (1-2 wei)
    // Tests floor/ceiling division behavior with minimal inputs
    // ============================================

    function test_xycSwap_minimalAmounts_1wei_ExactIn() public {
        // 1 wei input on balanced pool - tests floor division
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_A); // 1:1 ratio
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(1, true, true); // 1 wei exactIn

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // Expected: amountOut = (1 * 1000e18) / (1000e18 + 1) ≈ 0 (floor division)
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swap(swapProgram, order);
    }

    function test_xycSwap_minimalAmounts_1wei_ExactOut() public {
        // 1 wei output on balanced pool - tests ceiling division
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_A); // 1:1 ratio
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(1, true, false); // 1 wei exactOut

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // Expected: amountIn = ceil((1 * 1000e18) / (1000e18 - 1)) = 2 (ceiling division)
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        assertEq(amountOut, 1, "Amount out should be exactly 1 wei");
        assertGe(amountIn, 2, "Amount in should be at least 1 wei due to ceiling division");
    }

    function test_xycSwap_minimalAmounts_2wei_ExactIn() public {
        // 2 wei input on balanced pool
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_A); // 1:1 ratio
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(2, true, true); // 2 wei exactIn

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // Expected: amountOut = (2 * 1000e18) / (1000e18 + 2) ≈ 1 (floor division)
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        assertEq(amountIn, 2, "Amount in should be exactly 2 wei");
        assertGe(amountOut, 1, "Amount out should be at least 1 wei");
    }

    function test_xycSwap_minimalAmounts_2wei_ExactOut() public {
        // 2 wei output on balanced pool
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, INITIAL_BALANCE_A); // 1:1 ratio
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(2, true, false); // 2 wei exactOut

        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        assertEq(amountOut, 2, "Amount out should be exactly 2 wei");
        assertGe(amountIn, 2, "Amount in should be at least 2 wei due to ceiling division");
    }

    // ============================================
    // HIGH PRIORITY: Near-Depletion Scenarios
    // Tests behavior when amountOut approaches balanceOut
    // ============================================

    function test_xycSwap_nearDepletion_ExactIn() public {
        // Try to swap almost all of tokenB out
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        // With XYC formula: amountOut = (amountIn * balanceB) / (balanceA + amountIn)
        // To get amountOut ≈ balanceB - 1, we need very large amountIn
        // Let's use amountIn that would give us ~99.9% of balanceB
        uint256 largeAmountIn = 999000e18; // This should give ~999e18 out of 1000e18
        
        SwapProgram memory swapProgram = _swapProgram(largeAmountIn, true, true);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        // Verify near-depletion behavior
        assertGt(amountIn, 0, "Amount in should be greater than zero");
        assertGt(amountOut, 0, "Amount out should be greater than zero");
        assertLt(amountOut, balanceB, "Amount out should be less than balance B");
    }

    function test_xycSwap_nearDepletion_ExactOut() public {
        // Request almost all of tokenB (balanceB - 1)
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        uint256 nearFullAmountOut = balanceB - 1; // 999999999999999999999
        SwapProgram memory swapProgram = _swapProgram(nearFullAmountOut, true, false);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        assertEq(amountOut, nearFullAmountOut, "Amount out should equal requested near-full amount");
        assertGt(amountIn, 0, "Amount in should be greater than zero");
    }

    function test_xycSwap_exactDepletion_reverts() public {
        // Request exactly all of tokenB (balanceB) - should cause division by zero
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        uint256 fullAmountOut = balanceB; // Exact balance
        SwapProgram memory swapProgram = _swapProgram(fullAmountOut, true, false);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // ExactOut formula: amountIn = ceil((amountOut * balanceIn) / (balanceOut - amountOut))
        // When amountOut == balanceOut, denominator = 0 → division by zero
        vm.expectRevert(); // Reverts with panic: division or modulo by zero (0x12)
        swap(swapProgram, order);
    }

    // ============================================
    // Extreme Price Ratios
    // Tests with highly imbalanced pools (1000000:1 and 1:1000000)
    // ============================================

    function test_xycSwap_extremeRatio_1000000_to_1_ExactIn() public {
        // balanceA >> balanceB (1,000,000:1)
        uint256 balanceA = 1000000e18;
        uint256 balanceB = 1e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        // Swap 1e18 tokenA for tokenB
        SwapProgram memory swapProgram = _swapProgram(1e18, true, true);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        // Expected: very small amountOut due to extreme ratio
        // amountOut = (1e18 * 1e18) / (1000000e18 + 1e18) ≈ 0.000001e18 = 1e12
        assertEq(amountIn, 1e18, "Amount in should be 1e18");
        assertGt(amountOut, 0, "Amount out should be greater than zero");
        assertLt(amountOut, 1e15, "Amount out should be very small due to extreme ratio");
    }

    function test_xycSwap_extremeRatio_1000000_to_1_ExactOut() public {
        // balanceA >> balanceB (1,000,000:1)
        uint256 balanceA = 1000000e18;
        uint256 balanceB = 1e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        // Request small amount out
        uint256 requestedOut = 1e12; // 0.000001 token
        SwapProgram memory swapProgram = _swapProgram(requestedOut, true, false);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        assertEq(amountOut, requestedOut, "Amount out should match requested");
        assertGt(amountIn, 0, "Amount in should be greater than zero");
    }

    function test_xycSwap_extremeRatio_1_to_1000000_ExactIn() public {
        // balanceA << balanceB (1:1,000,000)
        uint256 balanceA = 1e18;
        uint256 balanceB = 1000000e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        // Swap small amount of tokenA for tokenB
        uint256 smallIn = 1e12; // 0.000001 token
        SwapProgram memory swapProgram = _swapProgram(smallIn, true, true);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        // Expected: large amountOut due to extreme ratio
        assertEq(amountIn, smallIn, "Amount in should match requested");
        assertGt(amountOut, amountIn, "Amount out should be larger than input due to ratio");
    }

    function test_xycSwap_extremeRatio_1_to_1000000_ExactOut() public {
        // balanceA << balanceB (1:1,000,000)
        uint256 balanceA = 1e18;
        uint256 balanceB = 1000000e18;
        MakerSetup memory setup = _makerSetup(balanceA, balanceB);
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        
        // Request large amount out
        uint256 requestedOut = 1e18; // 1 token
        SwapProgram memory swapProgram = _swapProgram(requestedOut, true, false);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        
        assertEq(amountOut, requestedOut, "Amount out should match requested");
        assertGt(amountIn, 0, "Amount in should be greater than zero");
        // amountIn should be very small compared to amountOut
        assertLt(amountIn, amountOut, "Amount in should be less than amount out due to ratio");
    }

    // ============================================
    // Zero Balance Revert Tests
    // Tests that zero balances properly revert
    // ============================================

    function test_xycSwap_zeroBalanceIn_reverts() public {
        // Create a strategy with zero balanceA
        // This requires shipping with zero balance which should fail at instruction level
        MakerSetup memory setup = _makerSetup(0, INITIAL_BALANCE_B);
        ISwapVM.Order memory order = createStrategy(setup);
        
        // Ship with non-zero to make it valid, then we'll test the instruction behavior
        // Note: The XYCSwap instruction checks ctx.swap.balanceIn and ctx.swap.balanceOut
        // which come from the dynamic balances, not the shipped balances
        // So we ship with valid balances but the program has zero in dynamic balances
        shipStrategy(order, tokenA, tokenB, 0, setup.balanceB);
        
        SwapProgram memory swapProgram = _swapProgram(1e18, true, true);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // Should revert because balanceIn is 0
        vm.expectRevert(); // XYCSwapRequiresBothBalancesNonZero
        swap(swapProgram, order);
    }

    function test_xycSwap_zeroBalanceOut_reverts() public {
        // Create a strategy with zero balanceB
        MakerSetup memory setup = _makerSetup(INITIAL_BALANCE_A, 0);
        ISwapVM.Order memory order = createStrategy(setup);
        
        shipStrategy(order, tokenA, tokenB, setup.balanceA, 0);
        
        SwapProgram memory swapProgram = _swapProgram(1e18, true, true);
        mintTokenInToTaker(swapProgram, type(uint256).max);
        mintTokenOutToMaker(swapProgram, type(uint256).max);

        // Should revert because balanceOut is 0
        vm.expectRevert(); // XYCSwapRequiresBothBalancesNonZero
        swap(swapProgram, order);
    }
}
