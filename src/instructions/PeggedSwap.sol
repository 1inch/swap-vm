// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { PeggedSwapMath } from "../libs/PeggedSwapMath.sol";

/// @notice PeggedSwap opcode, swap curve for pegged assets
/// @dev Encoding: [uint256 x0, uint256 y0, uint256 linearWidth, uint256 rateA, uint256 rateB]
library PeggedSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error PeggedSwapInvalidLinearWidth(uint256 linearWidth);
    error PeggedSwapInvalidInitialBalances(uint256 x0, uint256 y0);
    error PeggedSwapInvalidRates(uint256 rateA, uint256 rateB);

    Opcode constant opcode = Opcode.PeggedSwap;

    /// @param x0 Initial X reserve (normalization factor) = initial_balance_X * rateA (or rateB)
    /// @param y0 Initial Y reserve (normalization factor) = initial_balance_Y * rateB (or rateA)
    /// @param linearWidth Linear component coefficient A scaled by 1e27 (e.g., 100e27 for A=100)
    /// @param rateA Rate multiplier for token with LOWER address
    /// @param rateB Rate multiplier for token with GREATER address
    ///   For equal decimals (e.g., both 18): rateA = rateB = 1
    ///   For 18 vs 6 decimals: rate18 = 1, rate6 = 1e12 (to scale up to common precision)
    /// @dev Curvature is hardcoded to p=0.5 for optimal gas efficiency and proven behavior
    /// @dev Rates are assigned based on token address comparison
    /// @dev When tokenIn < tokenOut: rateIn = rateA, rateOut = rateB
    /// @dev When tokenIn > tokenOut: rateIn = rateB, rateOut = rateA
    /// @dev Example for 1000 USDC (6 dec) and 1000 DAI (18 dec), USDC < DAI:
    ///   rateA = 1e12, rateB = 1
    ///   x0 = 1000e6 * 1e12 = 1000e18, y0 = 1000e18 * 1 = 1000e18
    function build(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateA,
        uint256 rateB
    ) internal pure returns (bytes memory) {
        require(x0 > 0 && y0 > 0, PeggedSwapInvalidInitialBalances(x0, y0));
        require(linearWidth <= PeggedSwapMath.MAX_LINEAR_WIDTH, PeggedSwapInvalidLinearWidth(linearWidth));
        require(rateA > 0 && rateB > 0, PeggedSwapInvalidRates(rateA, rateB));

        bytes memory args = abi.encodePacked(x0, y0, linearWidth, rateA, rateB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint256 x0, uint256 y0, uint256 linearWidth, uint256 rateA, uint256 rateB) {
        x0 = args.at(0).asU256();
        y0 = args.at(32).asU256();
        linearWidth = args.at(64).asU256();
        rateA = args.at(96).asU256();
        rateB = args.at(128).asU256();
    }

    // ╔═══════════════════════════════════════════════════════════════════════════╗
    // ║  PEGGED SWAP CURVE FOR PEGGED ASSETS                                      ║
    // ║                                                                           ║
    // ║  Formula: √(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A                      ║
    // ║                                                                           ║
    // ║  Where:                                                                   ║
    // ║    - x, y are current reserves (in SwapVM: balanceIn, balanceOut)         ║
    // ║    - X₀, Y₀ are initial reserves (normalization factors)                  ║
    // ║    - A is linear width parameter (0 to 5000e+27, inclusive)               ║
    // ║    - Curvature p=0.5 is hardcoded for analytical solution                 ║
    // ║                                                                           ║
    // ║  Rate multipliers:                                                        ║
    // ║    - rateA/rateB scale tokens to common base                              ║
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
    // ║    - WARNING: This curve has finite reserves (hard price boundary).       ║
    // ║      NOT suitable for drifting-peg assets where the ratio changes         ║
    // ║      over time without a moving anchor.                                   ║
    // ╚═══════════════════════════════════════════════════════════════════════════╝
    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 x0_init;
        uint256 y0_init;
        uint256 linearWidth;
        uint256 rateIn;
        uint256 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (x0_init, y0_init, linearWidth, rateIn, rateOut) = parse(args);
        else (y0_init, x0_init, linearWidth, rateOut, rateIn) = parse(args);

        // Apply rate multipliers to normalize to common scale (1e18)
        uint256 x0 = ctx.swap.balanceIn * rateIn;
        uint256 y0 = ctx.swap.balanceOut * rateOut;

        // Calculate target invariant from initial state (using normalized values)
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            x0,
            y0,
            x0_init,
            y0_init,
            linearWidth
        );

        if (ctx.query.isExactIn) {
            // ExactIn: calculate y1 from x1 = x0 + amountIn (normalized)
            uint256 x1 = x0 + ctx.swap.amountIn * rateIn;

            // Solve for y1: given x1, find y1 that maintains invariant
            // x1 * ONE / x0 - safe: x1 ≤ 1e30, ONE = 1e27 → 1e57 < 1e77
            uint256 u1 = x1 * PeggedSwapMath.ONE / x0_init;  // Round DOWN u1
            uint256 v1 = PeggedSwapMath.solve(u1, linearWidth, targetInvariant);

            // Round UP y1 (normalized) to ensure amountOut rounds DOWN (protects maker)
            // v1 * y0_init - safe: v1 ≤ u* ≤ 4e27 (boundary for any A ≥ 0), y0_init ≤ 1e30 → 4e57 < 1e77
            uint256 y1 = Math.ceilDiv(v1 * y0_init, PeggedSwapMath.ONE);

            // Convert back from normalized scale: amountOut = (y0 - y1) / rateOut
            // Round DOWN to protect maker
            ctx.swap.amountOut = (y0 - y1) / rateOut;
        } else {
            // ExactOut: calculate x1 from y1 = y0 - amountOut (normalized)
            uint256 y1 = y0 - ctx.swap.amountOut * rateOut;

            // Solve for x1: given y1, find x1 that maintains invariant
            // y1 * ONE / y0 - safe: y1 ≤ 1e30, ONE = 1e27 → 1e57 < 1e77
            uint256 v1 = y1 * PeggedSwapMath.ONE / y0_init;  // Round DOWN v1
            uint256 u1 = PeggedSwapMath.solve(v1, linearWidth, targetInvariant);

            // Round UP x1 (normalized) to ensure amountIn rounds UP (protects maker)
            // u1 * x0_init - safe: u1 ≤ u* ≤ 4e27 (boundary for any A ≥ 0), x0_init ≤ 1e30 → 4e57 < 1e77
            uint256 x1 = Math.ceilDiv(u1 * x0_init, PeggedSwapMath.ONE);

            // Convert back from normalized scale: amountIn = (x1 - x0) / rateIn
            // Round UP to protect maker
            uint256 amountIn = Math.ceilDiv(x1 - x0, rateIn);

            // least 1 wei of tokenIn for any nonzero output (maker-favorable, matches the ceilDiv intent).
            if (amountIn == 0 && ctx.swap.amountOut != 0) {
                amountIn = 1;
            }

            ctx.swap.amountIn = amountIn;
        }
    }
}
