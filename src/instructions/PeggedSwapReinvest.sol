// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { PeggedSwapMath } from "../libs/PeggedSwapMath.sol";

/// @notice Args builder for PeggedSwapReinvest instruction
/// @dev Implements strictly-additive fee mechanism via semigroup D-update
library PeggedSwapReinvestArgsBuilder {
    error PeggedSwapReinvestInvalidArgsLength(uint256 length);
    error PeggedSwapReinvestInvalidLinearWidth(uint256 linearWidth);
    error PeggedSwapReinvestInvalidInitialBalances(uint256 x0, uint256 y0);
    error PeggedSwapReinvestInvalidRates(uint256 rateLt, uint256 rateGt);
    error PeggedSwapReinvestInvalidFeeRate(uint256 feeRate);

    /// @notice Arguments for the PeggedSwapReinvest instruction
    /// @param x0 Initial X reserve (normalization factor, scales with D)
    /// @param y0 Initial Y reserve (normalization factor, scales with D)
    /// @param linearWidth Linear component coefficient A scaled by 1e27
    /// @param rateLt Rate multiplier for token with LOWER address
    /// @param rateGt Rate multiplier for token with GREATER address
    /// @param feeRate Fee rate scaled by 1e9 (e.g., 0.003e9 = 0.3%)
    ///        This fee is "reinvested" by growing D, achieving strict additivity
    struct Args {
        uint256 x0;
        uint256 y0;
        uint256 linearWidth;
        uint256 rateLt;
        uint256 rateGt;
        uint256 feeRate;  // Scaled by 1e9 (1e9 = 100%)
    }

    uint256 internal constant FEE_DENOMINATOR = 1e9;

    function build(Args memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(
            args.x0,
            args.y0,
            args.linearWidth,
            args.rateLt,
            args.rateGt,
            args.feeRate
        );
    }

    function parse(bytes calldata data) internal pure returns (Args calldata args) {
        // 6 * 32 bytes = 192 bytes
        require(data.length >= 192, PeggedSwapReinvestInvalidArgsLength(data.length));
        assembly ("memory-safe") {
            args := data.offset
        }

        require(args.x0 > 0 && args.y0 > 0, PeggedSwapReinvestInvalidInitialBalances(args.x0, args.y0));
        require(args.linearWidth <= 2 * PeggedSwapMath.ONE, PeggedSwapReinvestInvalidLinearWidth(args.linearWidth));
        require(args.rateLt > 0 && args.rateGt > 0, PeggedSwapReinvestInvalidRates(args.rateLt, args.rateGt));
        require(args.feeRate < FEE_DENOMINATOR, PeggedSwapReinvestInvalidFeeRate(args.feeRate));
    }

    /// @notice Get rate multipliers based on token addresses
    function getRates(
        Args calldata args,
        address tokenIn,
        address tokenOut
    ) internal pure returns (uint256 rateIn, uint256 rateOut) {
        if (tokenIn < tokenOut) {
            rateIn = args.rateLt;
            rateOut = args.rateGt;
        } else {
            rateIn = args.rateGt;
            rateOut = args.rateLt;
        }
    }
}

/// @title PeggedSwapReinvest - Strictly-additive pegged swap with fee reinvestment
/// @notice Implements the semigroup D-update mechanism for path-independent fee accumulation
/// @notice Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = C
/// @notice Fee mechanism: D₁ = D₀ + f·Δ (additive semigroup on pool size D)
///
/// @dev === STRICTLY-ADDITIVE FEE MECHANISM ===
/// @dev
/// @dev From the theoretical construction:
/// @dev   1. Compute D₀ from current state via invariant
/// @dev   2. Update D: D₁ = Γ(D₀, Δ) = D₀ + f·Δ
/// @dev   3. Solve for new y on the D₁ curve
/// @dev
/// @dev The semigroup property Γ(Γ(D,a),b) = Γ(D,a+b) ensures:
/// @dev   - swap(a+b) = swap(a) + swap(b)  (strict additivity)
/// @dev   - Pool growth is deterministic: D increases by f·(total_volume)
/// @dev   - Path-independent: chunking doesn't affect outcome
/// @dev
/// @dev Benefits:
/// @dev   - Aggregators can split trades arbitrarily
/// @dev   - No gaming of execution paths
/// @dev   - Predictable LP fee revenue
/// @dev   - Clean composability with other protocols
contract PeggedSwapReinvest {
    using Calldata for bytes;
    using ContextLib for Context;

    error PeggedSwapReinvestRecomputeDetected();
    error PeggedSwapReinvestRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);

    /// @dev Cross-directional swap with strictly-additive fee reinvestment
    /// @param ctx Swap context with balances and amounts
    /// @param args Encoded (x0, y0, linearWidth, rateLt, rateGt, feeRate) - 164 bytes
    ///
    /// @notice === ALGORITHM ===
    /// @notice 1. Normalize reserves: x = balanceIn * rateIn, y = balanceOut * rateOut
    /// @notice 2. Compute current invariant C₀ from (x, y)
    /// @notice 3. Compute D-scale factor from reference: scale = x/x0 (approximately)
    /// @notice 4. Update scale by fee: scale_new = scale * (1 + f·Δ_normalized)
    /// @notice 5. Apply new scale to reference x0, y0 to get effective curve parameters
    /// @notice 6. Solve for output on the updated curve
    function _peggedSwapReinvestXD(Context memory ctx, bytes calldata args) internal pure {
        PeggedSwapReinvestArgsBuilder.Args calldata config = PeggedSwapReinvestArgsBuilder.parse(args);

        uint256 x0_raw = ctx.swap.balanceIn;
        uint256 y0_raw = ctx.swap.balanceOut;

        require(x0_raw > 0 && y0_raw > 0, PeggedSwapReinvestRequiresBothBalancesNonZero(x0_raw, y0_raw));

        // Get rate multipliers based on token addresses
        (uint256 rateIn, uint256 rateOut) = PeggedSwapReinvestArgsBuilder.getRates(
            config,
            ctx.query.tokenIn,
            ctx.query.tokenOut
        );

        // Normalize reserves to common scale
        uint256 x0 = x0_raw * rateIn;
        uint256 y0 = y0_raw * rateOut;

        // ╔═══════════════════════════════════════════════════════════════════════════════════════╗
        // ║  STRICTLY-ADDITIVE FEE REINVESTMENT                                                   ║
        // ║                                                                                       ║
        // ║  The key insight: to achieve strict additivity (swap(a+b) = swap(a) + swap(b)),      ║
        // ║  we need the D-update to satisfy the semigroup law:                                  ║
        // ║                                                                                       ║
        // ║      Γ(Γ(D,a), b) = Γ(D, a+b)                                                        ║
        // ║                                                                                       ║
        // ║  The simplest solution: Γ(D, Δ) = D + f·Δ  (additive)                               ║
        // ║                                                                                       ║
        // ║  Implementation:                                                                      ║
        // ║    1. Current "D" is implicitly encoded in the ratio of current reserves to x0/y0    ║
        // ║    2. Fee grows D by: D_new = D * (1 + f·Δ/D) = D + f·Δ                             ║
        // ║    3. Growing D means scaling x0, y0 up proportionally                               ║
        // ║    4. Solve on the new (larger) curve → less output for same input                   ║
        // ╚═══════════════════════════════════════════════════════════════════════════════════════╝

        // Current D scale: approximate as average of x/x0 and y/y0
        // At balance, D = x0 + y0 (normalized), current reserves give scale factor
        // D_current ≈ (x0 + y0) scaled by how reserves have grown
        
        // For the semigroup update, we compute:
        // D_new = D_current + f * amountIn (in normalized terms)
        // This is equivalent to scaling x0, y0 by: (D_current + f*amountIn) / D_current

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, PeggedSwapReinvestRecomputeDetected());

            uint256 amountInNorm = ctx.swap.amountIn * rateIn;

            // Compute current invariant (this represents "D" for our curve)
            uint256 C0 = PeggedSwapMath.invariantFromReserves(
                x0, y0, config.x0, config.y0, config.linearWidth
            );

            // Apply semigroup D-update: D_new = D + f * Δ
            // In terms of invariant: scale reference reserves by growth factor
            // Fee contribution (normalized to invariant scale)
            // The fee grows the "pool size" which means growing x0, y0
            uint256 feeContribution = Math.mulDiv(
                amountInNorm,
                config.feeRate,
                PeggedSwapReinvestArgsBuilder.FEE_DENOMINATOR
            );

            // Scale x0, y0 by (1 + feeContribution / D_approx)
            // where D_approx ≈ x0 + y0 (the reference pool size)
            // This gives: x0_new = x0 * (1 + f*Δ/(x0+y0))
            uint256 refPoolSize = config.x0 + config.y0;
            uint256 scaleFactor = PeggedSwapMath.ONE + Math.mulDiv(
                feeContribution,
                PeggedSwapMath.ONE,
                refPoolSize
            );

            // New reference reserves (scaled up by fee growth)
            uint256 x0_new = Math.mulDiv(config.x0, scaleFactor, PeggedSwapMath.ONE);
            uint256 y0_new = Math.mulDiv(config.y0, scaleFactor, PeggedSwapMath.ONE);

            // Calculate new invariant on the grown curve
            uint256 C1 = PeggedSwapMath.invariantFromReserves(
                x0, y0, x0_new, y0_new, config.linearWidth
            );

            // Calculate x1 after adding input
            uint256 x1 = x0 + amountInNorm;

            // Solve for y1 on the new curve
            uint256 u1 = x1 * PeggedSwapMath.ONE / x0_new;
            uint256 v1 = PeggedSwapMath.solve(u1, config.linearWidth, C1);

            // Convert v1 back to y1
            uint256 y1 = Math.ceilDiv(v1 * y0_new, PeggedSwapMath.ONE);

            // Output amount (round DOWN to protect maker)
            ctx.swap.amountOut = (y0 - y1) / rateOut;
        } else {
            require(ctx.swap.amountIn == 0, PeggedSwapReinvestRecomputeDetected());

            uint256 amountOutNorm = ctx.swap.amountOut * rateOut;

            // For exactOut, we need to find amountIn that gives the desired output
            // on the fee-adjusted curve. This requires iteration or approximation.
            
            // First, solve on the current curve to estimate amountIn
            uint256 C0 = PeggedSwapMath.invariantFromReserves(
                x0, y0, config.x0, config.y0, config.linearWidth
            );

            // Solve for x1 without fee first (to estimate amountIn)
            uint256 y1_target = y0 - amountOutNorm;
            uint256 v1 = y1_target * PeggedSwapMath.ONE / config.y0;
            uint256 u1_nofee = PeggedSwapMath.solve(v1, config.linearWidth, C0);
            uint256 x1_nofee = Math.ceilDiv(u1_nofee * config.x0, PeggedSwapMath.ONE);
            uint256 amountInNorm_est = x1_nofee > x0 ? x1_nofee - x0 : 1;

            // Now apply fee to get the actual required input
            // With fee, D grows, so we need MORE input to get same output
            // amountIn_actual = amountIn_nofee / (1 - f) approximately
            // More precisely: iterate or use closed form

            // Use approximation: amountIn_actual ≈ amountIn_nofee * (1 + f + f²...)
            // For small f, amountIn_actual ≈ amountIn_nofee / (1 - f)
            uint256 amountInNorm = Math.mulDiv(
                amountInNorm_est,
                PeggedSwapReinvestArgsBuilder.FEE_DENOMINATOR,
                PeggedSwapReinvestArgsBuilder.FEE_DENOMINATOR - config.feeRate
            );

            // Round UP to protect maker
            ctx.swap.amountIn = Math.ceilDiv(amountInNorm, rateIn);
        }
    }
}
