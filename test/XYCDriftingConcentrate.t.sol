// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCDriftingConcentrate, XYCDriftingConcentrateArgsBuilder } from "../src/instructions/XYCDriftingConcentrate.sol";

import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";
import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

/// @notice Draft tests for the drifting concentrated-liquidity instruction:
///   - first swap identical to static XYCConcentrate (same initial curve, no drift yet)
///   - swap persists the range state (center, budget, timestamp), quote does not
///   - within one block the curve is frozen: marginal price continuous, round trips unprofitable
///   - across time the range drifts toward the inventory-implied center: the free portion at
///     baseDriftRatePerSecond, the funded portion paid from the fee budget at cost 2*d
///   - budget accrues per swap as budgetRate * amountOut / balanceOut, post-swap
contract XYCDriftingConcentrateTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    uint256 constant BAL = 1000e18;
    uint256 constant SWAP_AMOUNT = 500e18;
    uint256 constant DUST = 1e12;
    uint256 constant DRIFT_RATE = 0.0001e18;   // total speed limit: 1 bp per second
    uint256 constant BASE_RATE = 0.00001e18;   // free floor: 0.1 bp per second
    uint256 constant BUDGET_RATE = 0.003e18;   // budget grant per swap (30 bp), keep <= fee

    /// @dev Geometric +-5% price range around 1.0: [1/1.05, 1.05] in 1e18 fp
    function _sqrtBounds() internal pure returns (uint256 sqrtPmin, uint256 sqrtPmax) {
        sqrtPmin = Math.sqrt(uint256(1e36) / 1.05e18 * 1e18);
        sqrtPmax = Math.sqrt(1.05e18 * 1e18);
    }

    function _driftingOrderCustom(uint256 rate, uint256 baseRate, uint256 budgetRate)
        internal
        view
        returns (ISwapVM.Order memory)
    {
        (uint256 sqrtPmin, uint256 sqrtPmax) = _sqrtBounds();
        Program p;
        return createStrategy(p.build(
            Opcode.XYCDriftingConcentrateSwap,
            XYCDriftingConcentrateArgsBuilder.build(sqrtPmin, sqrtPmax, rate, baseRate, budgetRate)
        ));
    }

    function _driftingOrder() internal view returns (ISwapVM.Order memory) {
        return _driftingOrderCustom(DRIFT_RATE, BASE_RATE, BUDGET_RATE);
    }

    function _staticOrder() internal view returns (ISwapVM.Order memory) {
        (uint256 sqrtPmin, uint256 sqrtPmax) = _sqrtBounds();
        Program p;
        return createStrategy(p.build(
            Opcode.XYCConcentrateSwap,
            XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
        ));
    }

    function _ship(ISwapVM.Order memory order) internal returns (bytes32 orderHash) {
        tokenA.mint(maker, BAL);
        tokenB.mint(maker, BAL);
        return shipStrategy(order, tokenA, tokenB, BAL, BAL);
    }

    function _sell(ISwapVM.Order memory order, bool zeroForOne, uint256 amount) internal returns (uint256, uint256) {
        SwapProgram memory sp = SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: zeroForOne,
            isExactIn: true
        });
        mintTokenInToTaker(sp, amount);
        return swap(sp, order);
    }

    function _quoteSell(ISwapVM.Order memory order, bool zeroForOne, uint256 amount) internal view returns (uint256, uint256) {
        SwapProgram memory sp = SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: zeroForOne,
            isExactIn: true
        });
        return quote(sp, order);
    }

    function _rangeState(bytes32 orderHash) internal view returns (uint96 center, uint96 budget, uint64 lastUpdate) {
        return XYCDriftingConcentrate(address(swapVM)).rangeState(orderHash);
    }

    function test_Drifting_FirstSwapMatchesStaticConcentrate() public {
        ISwapVM.Order memory drifting = _driftingOrder();
        ISwapVM.Order memory static_ = _staticOrder();
        _ship(drifting);
        _ship(static_);

        (uint256 inT, uint256 outT) = _quoteSell(drifting, true, SWAP_AMOUNT);
        (uint256 inS, uint256 outS) = _quoteSell(static_, true, SWAP_AMOUNT);

        assertEq(inT, inS, "amountIn should match static concentrate");
        // Bounds are re-derived from center/width with integer rounding, so allow dust-level deviation
        assertApproxEqRel(outT, outS, 1e6, "first-swap amountOut should match static concentrate");
    }

    function test_Drifting_SwapWritesStateQuoteDoesNot() public {
        ISwapVM.Order memory order = _driftingOrder();
        bytes32 orderHash = _ship(order);

        (uint256 sqrtPmin, uint256 sqrtPmax) = _sqrtBounds();
        uint256 initialCenter = Math.sqrt(sqrtPmin * sqrtPmax);

        _quoteSell(order, true, SWAP_AMOUNT);
        (uint96 center, uint96 budget, uint64 lastUpdate) = _rangeState(orderHash);
        assertEq(center, 0, "quote must not initialize the stored center");
        assertEq(budget, 0, "quote must not accrue budget");
        assertEq(lastUpdate, 0, "quote must not initialize the timestamp");

        (, uint256 out) = _sell(order, true, SWAP_AMOUNT);
        (center, budget, lastUpdate) = _rangeState(orderHash);
        assertEq(center, initialCenter, "first swap stores the args-derived center (no drift yet)");
        assertEq(budget, Math.mulDiv(BUDGET_RATE, out, BAL), "swap accrues budgetRate * amountOut / balanceOut");
        assertEq(lastUpdate, block.timestamp, "swap stores the drift baseline timestamp");
    }

    function test_Drifting_SameBlockCurveIsFrozen() public {
        ISwapVM.Order memory order = _driftingOrder();
        _ship(order);

        // Marginal price at the end of the upcoming swap, measured on the frozen pre-swap curve
        (, uint256 out1) = _quoteSell(order, true, SWAP_AMOUNT);
        (, uint256 out2) = _quoteSell(order, true, SWAP_AMOUNT + DUST);
        uint256 marginalOut = out2 - out1;

        _sell(order, true, SWAP_AMOUNT);

        // No time elapsed: no drift, the dust quote continues the exact same curve
        (, uint256 outAfter) = _quoteSell(order, true, DUST);
        assertApproxEqRel(outAfter, marginalOut, 1e12, "same-block marginal price must be continuous");
    }

    function test_Drifting_SameBlockRoundTripNotProfitable() public {
        ISwapVM.Order memory order = _driftingOrder();
        _ship(order);

        (, uint256 out) = _sell(order, true, SWAP_AMOUNT);   // sell A for B
        (, uint256 back) = _sell(order, false, out);         // sell all B back for A

        assertLe(back, SWAP_AMOUNT, "same-block sell/buy-back round trip must not be profitable");
    }

    function test_Drifting_BaseRateDriftIsFreeAndDeterministic() public {
        // budgetRate = 0 isolates the free base-rate portion: the funded move must be zero
        ISwapVM.Order memory drifting = _driftingOrderCustom(DRIFT_RATE, BASE_RATE, 0);
        ISwapVM.Order memory static_ = _staticOrder();
        bytes32 driftingHash = _ship(drifting);
        _ship(static_);

        // Skew inventory identically on both pools: heavy sell of tokenLt pushes price down
        _sell(drifting, true, SWAP_AMOUNT);
        _sell(static_, true, SWAP_AMOUNT);

        vm.warp(block.timestamp + 600);

        // The drifted (lower) range values tokenGt higher: a tokenGt seller receives more tokenLt
        (, uint256 outDrifting) = _quoteSell(drifting, false, DUST);
        (, uint256 outStatic) = _quoteSell(static_, false, DUST);
        assertGt(outDrifting, outStatic, "drifted range must quote better prices for rebalancing flow");

        // Any swap materializes the drift into storage: free portion only (no budget),
        // 600s at 0.1 bp/s = 0.6%, under the 2% global ceiling
        (uint96 centerBefore,,) = _rangeState(driftingHash);
        _sell(drifting, false, DUST);
        (uint96 centerAfter, uint96 budgetAfter,) = _rangeState(driftingHash);

        uint256 expected = centerBefore - Math.mulDiv(centerBefore, BASE_RATE * 600, 1e18);
        assertEq(centerAfter, expected, "free drift = baseRate * elapsed, exact");
        assertEq(budgetAfter, 0, "budgetRate = 0 must never accrue budget");
    }

    function test_Drifting_BudgetAccruesAndFundsDriftLinearly() public {
        // base = 0 isolates the funded portion: all movement must be paid at cost = 2 * d
        ISwapVM.Order memory order = _driftingOrderCustom(DRIFT_RATE, 0, BUDGET_RATE);
        bytes32 orderHash = _ship(order);

        (, uint256 out1) = _sell(order, true, SWAP_AMOUNT);
        (uint96 center1, uint96 budget1,) = _rangeState(orderHash);
        assertEq(budget1, Math.mulDiv(BUDGET_RATE, out1, BAL), "skew swap grants budgetRate * amountOut / balanceOut");

        vm.warp(block.timestamp + 600);

        // Materialize: requested paid move is 2% (rate-capped) costing 4% budget >> budget1,
        // so the move is clamped to budget1 / 2 and the budget is fully consumed
        uint256 balanceA = BAL + SWAP_AMOUNT;             // tokenA (in-side of the skew) balance
        (, uint256 outDust) = _sell(order, false, DUST);  // out-side of this swap is tokenA
        (uint96 center2, uint96 budget2,) = _rangeState(orderHash);

        uint256 expectedMove = Math.mulDiv(center1, uint256(budget1) / 2, 1e18);
        assertEq(center2, center1 - expectedMove, "funded drift is clamped to budget / 2");
        assertEq(budget2, Math.mulDiv(BUDGET_RATE, outDust, balanceA), "spent to zero, then re-accrued post-swap");
    }

    function test_Drifting_NoBaseNoBudgetMeansFrozenRange() public {
        ISwapVM.Order memory order = _driftingOrderCustom(DRIFT_RATE, 0, 0);
        bytes32 orderHash = _ship(order);

        _sell(order, true, SWAP_AMOUNT);
        (uint96 centerBefore,,) = _rangeState(orderHash);

        vm.warp(block.timestamp + 30 days);
        _sell(order, false, DUST);

        (uint96 centerAfter, uint96 budgetAfter,) = _rangeState(orderHash);
        assertEq(centerAfter, centerBefore, "no base rate and no budget: the range must not move");
        assertEq(budgetAfter, 0, "no accrual configured");
    }
}
