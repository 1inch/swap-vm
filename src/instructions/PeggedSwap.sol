// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { PeggedSwapMath } from "../libs/PeggedSwapMath.sol";

library PeggedSwapArgsBuilder {
    error PeggedSwapInvalidArgsLength(uint256 length);
    error PeggedSwapInvalidLinearWidth(uint256 linearWidth);
    error PeggedSwapInvalidInitialBalances(uint256 x0, uint256 y0);
    error PeggedSwapInvalidRates(uint256 rateLt, uint256 rateGt);

    /// @notice Arguments for the pegged swap instruction (stored in program)
    /// @param x0 Initial X reserve (normalization factor) = initial_balance_X * rateLt (or rateGt)
    /// @param y0 Initial Y reserve (normalization factor) = initial_balance_Y * rateGt (or rateLt)
    /// @param linearWidth Linear component coefficient A scaled by 1e27 (e.g., 100e27 for A=100); must be <= PeggedSwapMath.MAX_LINEAR_WIDTH
    /// @param rateLt Rate multiplier for token with LOWER address
    /// @param rateGt Rate multiplier for token with GREATER address
    ///        For equal decimals (e.g., both 18): rateLt = rateGt = 1
    ///        For 18 vs 6 decimals: rate18 = 1, rate6 = 1e12 (to scale up to common precision)
    /// @dev Curvature is hardcoded to p=0.5 for optimal gas efficiency and proven behavior
    /// @dev Rates are assigned based on token address comparison
    /// @dev When tokenIn < tokenOut: rateIn = rateLt, rateOut = rateGt
    /// @dev When tokenIn > tokenOut: rateIn = rateGt, rateOut = rateLt
    /// @dev Example for 1000 USDC (6 dec) and 1000 DAI (18 dec), USDC < DAI:
    ///      rateLt = 1e12, rateGt = 1
    ///      x0 = 1000e6 * 1e12 = 1000e18, y0 = 1000e18 * 1 = 1000e18
    struct Args {
        uint256 x0;
        uint256 y0;
        uint256 linearWidth;
        uint256 rateLt;
        uint256 rateGt;
    }

    /// @notice Build instruction arguments for PeggedSwap
    /// @param args Configuration for pegged swap curve
    /// @return Packed bytes for inclusion in program bytecode
    function build(Args memory args) internal pure returns (bytes memory) {
        require(args.x0 > 0 && args.y0 > 0, PeggedSwapInvalidInitialBalances(args.x0, args.y0));
        require(args.linearWidth <= PeggedSwapMath.MAX_LINEAR_WIDTH, PeggedSwapInvalidLinearWidth(args.linearWidth));
        require(args.rateLt > 0 && args.rateGt > 0, PeggedSwapInvalidRates(args.rateLt, args.rateGt));

        return abi.encodePacked(
            args.x0,
            args.y0,
            args.linearWidth,
            args.rateLt,
            args.rateGt
        );
    }

    function parse(bytes calldata data) internal pure returns (Args calldata args) {
        require(data.length >= 160, PeggedSwapInvalidArgsLength(data.length)); // 5 * 32 bytes
        assembly ("memory-safe") {
            args := data.offset // Zero-copy to calldata pointer casting
        }
    }

    /// @notice Get rate multipliers based on token addresses
    /// @param args Parsed arguments
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @return rateIn Rate multiplier for input token
    /// @return rateOut Rate multiplier for output token
    /// @return x0 Initial reserve for input token (normalization factor)
    /// @return y0 Initial reserve for output token (normalization factor)
    function parseRatesAndBalances(
        Args calldata args,
        address tokenIn,
        address tokenOut
    ) internal pure returns (uint256 rateIn, uint256 rateOut, uint256 x0, uint256 y0) {
        (rateIn, rateOut, x0, y0) = tokenIn < tokenOut ?
            (args.rateLt, args.rateGt, args.x0, args.y0) :
            (args.rateGt, args.rateLt, args.y0, args.x0);
    }
}


/// @title PeggedSwap - Square-root linear swap curve for pegged assets
/// @notice Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A
/// @notice Optimized for pegged assets (stablecoins, wrapped tokens, etc.)
/// @notice Calculates swap output directly using analytical solution with square root curve (p=0.5)
contract PeggedSwap {
    using ContextLib for Context;

    error PeggedSwapRecomputeDetected();
    error PeggedSwapBothBalancesZero();

    /// @dev Square-root linear swap with direct calculation
    /// @param ctx Swap context
    /// @param args Swap configuration (X0, Y0, linearWidth, rateLt, rateGt) - 160 bytes
    /// @notice Calculates output amount directly using analytical solution
    /// @notice Uses rate multipliers to normalize tokens with different decimals
    function _peggedSwapGrowPriceRange2D(Context memory ctx, bytes calldata args) internal pure {
        PeggedSwapArgsBuilder.Args calldata config = PeggedSwapArgsBuilder.parse(args);

        uint256 x0_raw = ctx.swap.balanceIn;
        uint256 y0_raw = ctx.swap.balanceOut;

        require(x0_raw | y0_raw != 0, PeggedSwapBothBalancesZero());

        // ╔═══════════════════════════════════════════════════════════════════════════╗
        // ║  PEGGED SWAP CURVE FOR PEGGED ASSETS                                      ║
        // ║                                                                           ║
        // ║  Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A                      ║
        // ║                                                                           ║
        // ║  Where:                                                                   ║
        // ║    - x, y are current reserves (in SwapVM: balanceIn, balanceOut)         ║
        // ║    - X₀, Y₀ are initial reserves (normalization factors)                  ║
        // ║    - A is linear width parameter (0 to 500e+27, inclusive)                ║
        // ║    - Curvature p=0.5 is hardcoded for analytical solution                 ║
        // ║                                                                           ║
        // ║  Rate multipliers:                                                        ║
        // ║    - rateLt/rateGt scale tokens to common base                            ║
        // ║    - Assigned based on token address comparison                           ║
        // ║                                                                           ║
        // ║  Benefits for pegged assets:                                              ║
        // ║    - Minimal slippage near 1:1 price (when A > 0)                         ║
        // ║    - Smooth price protection at extremes                                  ║
        // ║    - Analytical solution - no iterative solving needed                    ║
        // ║                                                                           ║
        // ║  Parameters guide (see docs/PeggedSwap/PeggedSwapWP.md §5):               ║
        // ║    - Tight stablecoin pairs (USDC/USDT, USDC/DAI):  A ≈ 100e+27-300e+27   ║
        // ║    - LST/LRT pairs (WETH/stETH, WETH/wstETH):       A ≈ 20e+27-100e+27    ║
        // ║    - Looser pegs / wrapped BTC pairs:               A ≈ 5e+27-20e+27      ║
        // ║    - Volatile / experimental:                       A ≈ 0-5e+27           ║
        // ║    - WARNING: This curve has finite reserves (hard price boundary).        ║
        // ║      NOT suitable for drifting-peg assets where the ratio changes         ║
        // ║      over time without a moving anchor.                                   ║
        // ╚═══════════════════════════════════════════════════════════════════════════╝

        // Get rate multipliers based on token addresses
        (uint256 rateIn, uint256 rateOut, uint256 x0_init, uint256 y0_init) = PeggedSwapArgsBuilder.parseRatesAndBalances(
            config,
            ctx.query.tokenIn,
            ctx.query.tokenOut
        );

        // Apply rate multipliers to normalize to common scale (1e18)
        uint256 x0 = x0_raw * rateIn;
        uint256 y0 = y0_raw * rateOut;

        // Calculate target invariant from initial state (using normalized values)
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            x0,
            y0,
            x0_init,
            y0_init,
            config.linearWidth
        );

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, PeggedSwapRecomputeDetected());
            // ExactIn: calculate y1 from x1 = x0 + amountIn (normalized)
            uint256 x1 = x0 + ctx.swap.amountIn * rateIn;

            // Solve for y1: given x1, find y1 that maintains invariant
            // x1 * ONE / x0 - safe: x1 ≤ 1e30, ONE = 1e27 → 1e57 < 1e77
            uint256 u1 = x1 * PeggedSwapMath.ONE / x0_init;  // Round DOWN u1
            uint256 v1 = PeggedSwapMath.solve(u1, config.linearWidth, targetInvariant);

            // Round UP y1 (normalized) to ensure amountOut rounds DOWN (protects maker)
            // v1 * y0_init - safe: v1 ≤ u* ≤ 4e27 (boundary for any A ≥ 0), y0_init ≤ 1e30 → 4e57 < 1e77
            uint256 y1 = Math.ceilDiv(v1 * y0_init, PeggedSwapMath.ONE);

            // Convert back from normalized scale: amountOut = (y0 - y1) / rateOut
            // Round DOWN to protect maker
            ctx.swap.amountOut = (y0 - y1) / rateOut;
        } else {
            require(ctx.swap.amountIn == 0, PeggedSwapRecomputeDetected());
            // ExactOut: calculate x1 from y1 = y0 - amountOut (normalized)
            uint256 y1 = y0 - ctx.swap.amountOut * rateOut;

            // Solve for x1: given y1, find x1 that maintains invariant
            // y1 * ONE / y0 - safe: y1 ≤ 1e30, ONE = 1e27 → 1e57 < 1e77
            uint256 v1 = y1 * PeggedSwapMath.ONE / y0_init;  // Round DOWN v1
            uint256 u1 = PeggedSwapMath.solve(v1, config.linearWidth, targetInvariant);

            // Round UP x1 (normalized) to ensure amountIn rounds UP (protects maker)
            // u1 * x0_init - safe: u1 ≤ u* ≤ 4e27 (boundary for any A ≥ 0), x0_init ≤ 1e30 → 4e57 < 1e77
            uint256 x1 = Math.ceilDiv(u1 * x0_init, PeggedSwapMath.ONE);

            // Convert back from normalized scale: amountIn = (x1 - x0) / rateIn
            // Round UP to protect maker
            ctx.swap.amountIn = Math.ceilDiv(x1 - x0, rateIn);
        }
    }
}
