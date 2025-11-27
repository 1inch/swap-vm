// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { PeggedSwapMath } from "../libs/PeggedSwapMath.sol";

library PeggedSwapArgsBuilder {
    /// @notice Arguments for the pegged swap instruction (stored in program)
    /// @param x0 Initial X reserve (normalization factor for x)
    /// @param y0 Initial Y reserve (normalization factor for y)
    /// @param linearWidth Linear component coefficient A (* 1e18, e.g., 0.8e18 for A=0.8)
    /// @dev Curvature is hardcoded to p=0.5 for optimal gas efficiency and proven behavior
    struct Args {
        uint256 x0;
        uint256 y0;
        uint256 linearWidth;
    }

    function build(Args memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(
            args.x0,
            args.y0,
            args.linearWidth
        );
    }

    function parse(bytes calldata data) internal pure returns (Args calldata args) {
        assembly ("memory-safe") {
            args := data.offset // Zero-copy to calldata pointer casting
        }
    }
}


/// @title PeggedSwap - Square-root linear swap curve for pegged assets
/// @notice Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A
/// @notice Optimized for pegged assets (stablecoins, wrapped tokens, etc.)
/// @notice Calculates swap output directly using analytical solution with square root curve (p=0.5)
contract PeggedSwap {
    using Calldata for bytes;
    using ContextLib for Context;

    uint256 private constant ONE = 1e18;

    error PeggedSwapInvalidArgs();
    error PeggedSwapInvalidBalances();

    function _divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// @dev Square-root linear swap with direct calculation
    /// @param ctx Swap context
    /// @param args Swap configuration (X0, Y0, linearWidth) - 96 bytes
    /// @notice Calculates output amount directly using analytical solution
    function _peggedSwapGrowPriceRange2D(Context memory ctx, bytes calldata args) internal pure {
        require(args.length >= 96, PeggedSwapInvalidArgs()); // 3 * 32 bytes

        PeggedSwapArgsBuilder.Args calldata config = PeggedSwapArgsBuilder.parse(args);

        require(config.x0 > 0 && config.y0 > 0, PeggedSwapInvalidArgs());
        require(config.linearWidth <= 2 * ONE, PeggedSwapInvalidArgs()); // A <= 2.0

        uint256 x0 = ctx.swap.balanceIn;
        uint256 y0 = ctx.swap.balanceOut;

        require(x0 > 0 && y0 > 0, PeggedSwapInvalidBalances());

        // ╔═══════════════════════════════════════════════════════════════════════════╗
        // ║  PEGGED SWAP CURVE FOR PEGGED ASSETS                                      ║
        // ║                                                                           ║
        // ║  Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A                      ║
        // ║                                                                           ║
        // ║  Where:                                                                   ║
        // ║    - x, y are current reserves (in SwapVM: balanceIn, balanceOut)         ║
        // ║    - X₀, Y₀ are initial reserves (normalization factors)                  ║
        // ║    - A is linear width parameter (0 to 2.0)                               ║
        // ║    - Curvature p=0.5 is hardcoded for analytical solution                 ║
        // ║                                                                           ║
        // ║  Benefits for pegged assets:                                              ║
        // ║    - Minimal slippage near 1:1 price (when A > 0)                         ║
        // ║    - Smooth price protection at extremes                                  ║
        // ║    - Analytical solution - no iterative solving needed                    ║
        // ║                                                                           ║
        // ║  Parameters guide:                                                        ║
        // ║    - For stablecoins (USDC/USDT): A ≈ 0.8-1.5                             ║
        // ║    - For wrapped tokens (WETH/stETH): A ≈ 0.3-0.6                         ║
        // ║    - For volatile pairs: A ≈ 0.0-0.2                                      ║
        // ╚═══════════════════════════════════════════════════════════════════════════╝

        // Calculate target invariant from initial state
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            x0,
            y0,
            config.x0,
            config.y0,
            config.linearWidth
        );

        // Calculate new state based on swap direction
        uint256 x1;
        uint256 y1;

        if (ctx.query.isExactIn) {
            // ExactIn: calculate y1 from x1 = x0 + amountIn
            x1 = x0 + ctx.swap.amountIn;

            // Solve for y1: given x1, find y1 that maintains invariant
            uint256 u1 = (x1 * ONE) / config.x0;  // Round DOWN u1
            uint256 v1 = PeggedSwapMath.solve(u1, config.linearWidth, targetInvariant);

            // Round UP y1 to ensure amountOut rounds DOWN
            y1 = _divRoundUp(v1 * config.y0, ONE);

            ctx.swap.amountOut = y0 - y1;
        } else {
            // ExactOut: calculate x1 from y1 = y0 - amountOut
            y1 = y0 - ctx.swap.amountOut;

            // Solve for x1: given y1, find x1 that maintains invariant
            uint256 v1 = (y1 * ONE) / config.y0;  // Round DOWN v1 (conservative)
            uint256 u1 = PeggedSwapMath.solve(v1, config.linearWidth, targetInvariant);

            // Round UP x1 to ensure amountIn rounds UP
            x1 = _divRoundUp(u1 * config.x0, ONE);

            ctx.swap.amountIn = x1 - x0;
        }

        // Update balances
        ctx.swap.balanceIn = x1;
        ctx.swap.balanceOut = y1;
    }
}

