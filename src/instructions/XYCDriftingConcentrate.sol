// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { ONE, XYCConcentrateArgsBuilder } from "./XYCConcentrate.sol";

library XYCDriftingConcentrateArgsBuilder {
    error DriftingConcentrateInvalidArgsLength(uint256 length);
    error DriftingConcentrateInvalidPriceBounds(uint256 sqrtPriceMin, uint256 sqrtPriceMax);

    /// @notice Build args for the drifting concentrate instruction
    /// @param sqrtPriceMin Initial sqrt(P_min) in 1e18 fp, P = tokenGt/tokenLt; the width
    ///        ratio sqrtPriceMax/sqrtPriceMin is preserved forever, only the center moves
    /// @param sqrtPriceMax Initial sqrt(P_max) in 1e18 fp; must fit uint96 (storage envelope,
    ///        allows sqrt-price up to ~7.9e28, i.e. price ratio up to ~6.2e21)
    /// @param driftRatePerSecond Max relative center drift per second (free + funded), 1e18 fp
    ///        (e.g. 0.0001e18 = 1 bp/s). Size it to the tracking speed the pair needs;
    ///        0 disables the drift entirely.
    /// @param baseDriftRatePerSecond Free (unfunded) relative drift per second, 1e18 fp.
    ///        Recovery floor that works with an empty budget. Sizing rule:
    ///        baseDriftRatePerSecond * expectedQuietGap <= fee - budgetRatePerSwap / 2
    ///        (e.g. fee/2 when budgetRatePerSwap = fee), so a skew-wait-harvest round trip
    ///        over a typical quiet period stays under its own fees even with the funded
    ///        drift stacked on top.
    /// @param budgetRatePerSwap Drift budget granted per swap, 1e18 fp: the grant is
    ///        budgetRatePerSwap * amountOut / balanceOut (fraction of the out-side inventory
    ///        the swap consumed). MUST be <= the order's actual swap fee, otherwise funded
    ///        drift can donate more than the position earns.
    function build(
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 driftRatePerSecond,
        uint256 baseDriftRatePerSecond,
        uint256 budgetRatePerSwap
    ) internal pure returns (bytes memory) {
        require(
            0 < sqrtPriceMin && sqrtPriceMin < sqrtPriceMax && sqrtPriceMax <= type(uint96).max,
            DriftingConcentrateInvalidPriceBounds(sqrtPriceMin, sqrtPriceMax)
        );
        return abi.encodePacked(sqrtPriceMin, sqrtPriceMax, driftRatePerSecond, baseDriftRatePerSecond, budgetRatePerSwap);
    }

    struct Args {
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint256 driftRatePerSecond;
        uint256 baseDriftRatePerSecond;
        uint256 budgetRatePerSwap;
    }

    function parse(bytes calldata data) internal pure returns (Args calldata args) {
        require(data.length >= 160, DriftingConcentrateInvalidArgsLength(data.length)); // 5 * 32 bytes

        assembly ("memory-safe") {
            args := data.offset // Zero-copy to calldata pointer casting
        }
        require(
            0 < args.sqrtPriceMin && args.sqrtPriceMin < args.sqrtPriceMax && args.sqrtPriceMax <= type(uint96).max,
            DriftingConcentrateInvalidPriceBounds(args.sqrtPriceMin, args.sqrtPriceMax)
        );
    }
}

/// @title XYCDriftingConcentrate - Concentrated liquidity with a drifting price range
/// @notice Terminal instruction: swaps on the current concentrated range exactly like
///         XYCConcentrate, but the range center drifts over time toward the inventory-implied
///         center, so the position follows the market instead of parking out of range.
///         The maker's Aqua balances never move to "rebalance" — the range shift is pure
///         arithmetic on virtual reserve offsets.
///
/// @dev DESIGN
///
///   Args carry the initial sqrt-price bounds plus three drift-economics parameters. Only the
///   geometric width g = sqrt(sqrtPmax0/sqrtPmin0) and the initial center
///   c0 = sqrt(sqrtPmin0*sqrtPmax0) are derived from the bounds; storage keeps one slot per
///   order: current center, drift budget, last update timestamp. Effective bounds for every
///   swap are [c/g, c*g]. L stays balance-derived, so fees and maker push/pull through Aqua
///   compound into liquidity exactly like in XYCConcentrate.
///
///   WHY DRIFT AND NOT PER-SWAP RECENTERING. With balance-derived L and a fixed width, the
///   triple (balances, center) fully determines the spot price, and the post-swap state is
///   already consistent with the current center. Re-solving "which center keeps the spot
///   unchanged" returns the old center (identity), and re-deriving the center from the balance
///   ratio jumps the spot by roughly the capital-efficiency multiplier (~40x for a +-5% range),
///   which lets a sell/buy-back round trip drain the position. The only self-consistent moving
///   target is the inventory-implied center c* = sqrt(balanceGt/balanceLt) — the unique center
///   at which the current balances would sit exactly range-centered. So between swaps the center
///   drifts toward c*, rate-limited in time:
///     - trades move inventory (and c*) toward the current range,
///     - drift moves the range toward inventory,
///     - arbitrage flow closes the loop at the market price.
///   In equilibrium the range is centered on the market price with balanced inventory, which is
///   the "range trails the price" behavior, achieved without any oracle.
///
///   FEE-FUNDED DRIFT BUDGET. Moving the center donates edge: a skew/unwind round trip of
///   volume v harvests ~2*d*v when the center moved d (relative) between the legs, paying
///   2*fee*v in fees. Drift is therefore split into:
///     - a FREE portion, capped by baseDriftRatePerSecond * elapsed — the recovery floor that
///       works even with an empty budget (one-sided positions, dead pairs);
///     - a FUNDED portion, capped by driftRatePerSecond * elapsed, paying cost = 2*dPaid out
///       of the stored budget (LINEAR displacement pricing) and shrinking to what the budget
///       affords (dPaid <= budget/2).
///   Linear pricing is deliberately update-pattern invariant: a displacement costs the same
///   whether materialized as one jump or as hundreds of tiny cranked steps, so patient
///   cranking cannot amplify what a budget buys. (A quadratic per-update cost was tried first
///   and rejected: it amortizes to zero over many small updates.)
///
///   The budget accrues per swap as budgetRatePerSwap * amountOut / balanceOut — the fraction
///   of the out-side inventory the swap consumed — AFTER the swap amounts are computed, so a
///   swap can never fund its own repricing. Per swap the grant is <= budgetRatePerSwap, and
///   dust-side wei swaps grant ~nothing (normalizing by amountIn/balanceIn instead would let
///   wei swaps into an empty side mint unbounded budget).
///
///   SELF-FINANCING. With budgetRatePerSwap = r <= fee: a skew of volume v grants budget
///   ~r*v/B (B = out-side balance), which buys dPaid ~r*v/(2B); the unwind harvests
///   2*dPaid*v ~ r*v^2/B, while the round trip pays 2*fee*v >= 2*r*v in fees. Harvest exceeds
///   fees only for v > 2B — impossible, since the band holds ~B of sellable inventory.
///   Stacking the free portion on top, the total harvest 2*(dFree + dPaid)*v stays below
///   2*fee*v for all v <= B when dFree <= fee - r/2, which is the base-rate sizing rule. So
///   drift is paid for by fees someone actually delivered, at any volume and any update
///   pattern.
///
///   MANIPULATION SURFACE. Within one block elapsed time is zero, the curve is frozen, and a
///   round trip can never be profitable (same as XYCConcentrate). Across blocks:
///     - skew-wait-harvest on the funded portion: self-financing per the bound above;
///     - wash-funding the budget: grants <= budgetRate * (relative volume), costs fee * volume,
///       same bound;
///     - harvesting an organically-funded budget: capped by fees the position already earned —
///       the attacker consumes repricing capacity the LP was paid for, never more;
///     - the free base rate is the residual exposure: holding a skew for time T harvests
///       ~2*(baseRate*T)*v against 2*fee*v in fees, so base-rate drift donates once
///       baseRate*T outgrows the fee margin. This is the declared, maker-sized cost of
///       oracle-free recovery (rule: baseRate * expected quiet gap <= fee - budgetRate/2;
///       set 0 to disable free drift entirely for pairs with reliable flow).
///   MAX_DRIFT_PER_UPDATE (2%) additionally caps any single materialized move as a circuit
///   breaker against maker misconfiguration.
///
/// @dev QUOTE/SWAP DIVERGENCE: quote applies the same deterministic drift for the current
///   block but never writes state (isStaticContext). Quotes are exact for swaps in the same
///   block; across blocks the drift accrues, like time-dependent instructions (Decay).
///
/// @dev A drained one-sided position keeps drifting toward the side that can refill it
///   (a pool out of tokenGt reprices downward until selling tokenGt to it beats the market,
///   and vice versa) at least at the base rate, plus whatever the draining flow itself funded,
///   so the position always finds its way back to two-sided quoting.
///   Drift is lazy: it accrues in time but only materializes when a swap (or quote) happens.
contract XYCDriftingConcentrate {
    error DriftingConcentrateRecomputeDetected(uint256 amountIn, uint256 amountOut);
    error DriftingConcentrateEmptyBounds(uint256 center, uint256 width);

    /// @dev Global ceiling on relative center movement per update, 1e18 fp (2%). Applies to the
    ///      free and funded portions independently; protects takers from absurd maker configs.
    uint256 public constant MAX_DRIFT_PER_UPDATE = 0.02e18;

    struct RangeState {
        uint96 sqrtPriceCenter; // current range center, sqrt-price 1e18 fp; 0 = uninitialized
        uint96 budget;          // drift budget, 1e18 fp fraction of pool balance (saturating)
        uint64 lastUpdate;      // timestamp of the last stored update
    }

    mapping(bytes32 orderHash => RangeState) public rangeState;

    /// @param args.sqrtPriceMin           | 32 bytes (uint256, 1e18 fp) — initial sqrt(P_min)
    /// @param args.sqrtPriceMax           | 32 bytes (uint256, 1e18 fp) — initial sqrt(P_max), <= uint96.max
    /// @param args.driftRatePerSecond     | 32 bytes (uint256, 1e18 fp) — max relative drift per second
    /// @param args.baseDriftRatePerSecond | 32 bytes (uint256, 1e18 fp) — free relative drift per second
    /// @param args.budgetRatePerSwap      | 32 bytes (uint256, 1e18 fp) — budget grant per swap, scaled by amountOut/balanceOut
    function _xycDriftingConcentrate2D(Context memory ctx, bytes calldata args) internal {
        XYCDriftingConcentrateArgsBuilder.Args calldata config = XYCDriftingConcentrateArgsBuilder.parse(args);

        // Immutable geometric half-width g = sqrt(sqrtPmax0/sqrtPmin0), 1e18 fp (> 1e18: parse validates the bounds)
        uint256 g = Math.sqrt(Math.mulDiv(config.sqrtPriceMax, ONE * ONE, config.sqrtPriceMin));

        bool isTokenInLt = ctx.query.tokenIn < ctx.query.tokenOut;
        uint256 bLt = isTokenInLt ? ctx.swap.balanceIn : ctx.swap.balanceOut;
        uint256 bGt = isTokenInLt ? ctx.swap.balanceOut : ctx.swap.balanceIn;

        // ---- drift of the range center toward the inventory-implied center ----
        // free portion at baseDriftRatePerSecond, funded portion paid from the budget

        RangeState memory state = rangeState[ctx.query.orderHash];
        uint256 center = state.sqrtPriceCenter == 0 ? Math.sqrt(config.sqrtPriceMin * config.sqrtPriceMax) : state.sqrtPriceCenter;
        uint256 budget = state.budget;

        if (state.lastUpdate != 0 && block.timestamp > state.lastUpdate) {
            uint256 elapsed = block.timestamp - state.lastUpdate;
            // c* = sqrt(bGt/bLt); a one-sided position drifts toward the side that can refill it
            // (moves floor to 0 for dust centers, so the center never collapses to zero)
            uint256 centerTarget = bLt == 0 ? type(uint256).max : Math.sqrt(Math.mulDiv(bGt, ONE * ONE, bLt));
            uint256 distance = centerTarget > center ? centerTarget - center : center - centerTarget;

            uint256 totalMove = Math.min(distance, Math.mulDiv(center, _driftCap(config.driftRatePerSecond, elapsed), ONE));
            uint256 freeMove = Math.min(totalMove, Math.mulDiv(center, _driftCap(config.baseDriftRatePerSecond, elapsed), ONE));
            uint256 paidMove = totalMove - freeMove;
            if (paidMove > 0) {
                (paidMove, budget) = _fundDrift(center, paidMove, budget);
            }

            center = centerTarget > center ? center + freeMove + paidMove : center - freeMove - paidMove;
            if (center > type(uint96).max) center = type(uint96).max; // storage envelope, degenerate by construction
        }

        uint256 sqrtPriceMin = Math.mulDiv(center, ONE, g);
        uint256 sqrtPriceMax = Math.mulDiv(center, g, ONE, Math.Rounding.Ceil);
        require(sqrtPriceMin > 0, DriftingConcentrateEmptyBounds(center, g));

        // ---- swap on the frozen current range: identical math to XYCConcentrate ----

        uint256 virtualBalanceIn;
        uint256 virtualBalanceOut;
        {
            uint256 liquidity = XYCConcentrateArgsBuilder._computeL(bLt, bGt, sqrtPriceMin, sqrtPriceMax);
            if (isTokenInLt) {
                virtualBalanceIn  = ctx.swap.balanceIn  + Math.mulDiv(liquidity, ONE, sqrtPriceMax, Math.Rounding.Ceil);
                virtualBalanceOut = ctx.swap.balanceOut + Math.mulDiv(liquidity, sqrtPriceMin, ONE);
            } else {
                virtualBalanceIn  = ctx.swap.balanceIn  + Math.mulDiv(liquidity, sqrtPriceMin, ONE, Math.Rounding.Ceil);
                virtualBalanceOut = ctx.swap.balanceOut + Math.mulDiv(liquidity, ONE, sqrtPriceMax);
            }
        }

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, DriftingConcentrateRecomputeDetected(ctx.swap.amountIn, ctx.swap.amountOut));
            uint256 out = (ctx.swap.amountIn * virtualBalanceOut) / (virtualBalanceIn + ctx.swap.amountIn);
            if (out > ctx.swap.balanceOut) {
                out = ctx.swap.balanceOut;
                ctx.swap.amountIn = Math.ceilDiv(out * virtualBalanceIn, virtualBalanceOut - out);
            }
            ctx.swap.amountOut = out;
        } else {
            require(ctx.swap.amountIn == 0, DriftingConcentrateRecomputeDetected(ctx.swap.amountIn, ctx.swap.amountOut));
            if (ctx.swap.amountOut > ctx.swap.balanceOut)
                ctx.swap.amountOut = ctx.swap.balanceOut;
            ctx.swap.amountIn = Math.ceilDiv(
                ctx.swap.amountOut * virtualBalanceIn,
                (virtualBalanceOut - ctx.swap.amountOut)
            );
        }

        // ---- accrue budget from this swap (post-swap: a swap cannot fund its own drift) ----
        // Grant is proportional to the fraction of out-side inventory consumed, <= budgetRate
        // per swap (amountOut <= balanceOut always). In-side normalization would be unbounded
        // for dust balances.

        if (config.budgetRatePerSwap > 0 && ctx.swap.amountOut > 0) {
            budget += Math.mulDiv(config.budgetRatePerSwap, ctx.swap.amountOut, ctx.swap.balanceOut);
            if (budget > type(uint96).max) budget = type(uint96).max; // saturating
        }

        // ---- persist center/budget/timestamp; drift accrues from the last stored swap ----

        if (!ctx.vm.isStaticContext) {
            rangeState[ctx.query.orderHash] = RangeState({
                sqrtPriceCenter: uint96(center), // clamped above; init center <= sqrtPriceMax <= uint96.max
                budget: uint96(budget),          // saturated above
                lastUpdate: uint64(block.timestamp)
            });
        }
    }

    /// @dev Relative drift cap for one update: rate * elapsed, ceiled by MAX_DRIFT_PER_UPDATE.
    ///      The rate is clamped before the multiply so rate * elapsed cannot overflow.
    function _driftCap(uint256 ratePerSecond, uint256 elapsed) private pure returns (uint256) {
        return Math.min(Math.min(ratePerSecond, MAX_DRIFT_PER_UPDATE) * elapsed, MAX_DRIFT_PER_UPDATE);
    }

    /// @dev Charge the funded drift portion to the budget at linear displacement pricing
    ///      (cost = 2 * dPaid, both 1e18 fp) and shrink the move to what the budget affords.
    ///
    ///      Linear in displacement means the cost of moving the center by a total D is 2*D no
    ///      matter how the movement is split across updates — there is nothing to gain from
    ///      cranking many small steps or from coalescing one big jump. The factor 2 converts a
    ///      center move into the price move (price ~ center^2) that a skew/unwind round trip
    ///      harvests per unit volume; together with the out-side accrual normalization it makes
    ///      any funded harvest cost more in fees than it yields (see SELF-FINANCING above).
    ///      On clamping, the whole budget is consumed (floor rounding donates dust to the maker).
    function _fundDrift(uint256 center, uint256 paidMove, uint256 budget)
        private
        pure
        returns (uint256 fundedMove, uint256 budgetLeft)
    {
        uint256 deltaPaid = Math.mulDiv(paidMove, ONE, center);
        uint256 cost = 2 * deltaPaid;
        if (cost <= budget) return (paidMove, budget - cost);
        return (Math.mulDiv(center, budget / 2, ONE), 0);
    }
}
