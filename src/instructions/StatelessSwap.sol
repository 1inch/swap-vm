// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/**
 * @title StatelessSwap - Dual Invariant Curve AMM with Fee Reinvestment
 *
 * @notice An AMM using direction-dependent invariant curves that automatically
 *         reinvest fees into the pool from BOTH swap directions.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                                    MAIN IDEA
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 * Traditional problem: With a single invariant curve y·x^α = K,
 *   - X→Y swaps reinvest fees (K_product grows)
 *   - Y→X swaps drain reserves (K_product shrinks)
 *
 * Solution: Use curve out·in^α = K for BOTH directions.
 *   - The exponent α always applies to the INPUT token
 *   - This ensures fees are captured from both directions
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                              INVARIANT CURVE
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                                                                 │
 * │   Invariant:  balanceOut · balanceIn^α = K                     │
 * │                                                                 │
 * │   Where:  α = 1 - φ  (φ = fee rate, e.g., 0.003 = 0.3%)        │
 * │                                                                 │
 * └─────────────────────────────────────────────────────────────────┘
 *
 * For X→Y: out = balanceY, in = balanceX → Y·X^α = K
 * For Y→X: out = balanceX, in = balanceY → X·Y^α = K'
 *
 * The curve "adapts" to the swap direction, always applying the
 * fee-inducing exponent to whichever token is being sold.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                                KEY PROPERTIES
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 *   ✓ STATELESS - works only with SwapVM registers (balances)
 *   ✓ BIDIRECTIONAL FEE REINVESTMENT - K_product grows in both directions
 *   ✓ PATH INDEPENDENT - deterministic output for any input
 *   ✓ SUBADDITIVE - single swap ≥ sum of split swaps
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                                  SWAP FORMULAS
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │ EXACT IN: Given Δin, compute Δout                              │
 * │                                                                 │
 * │   From invariant preservation:                                 │
 * │     (out - Δout) · (in + Δin)^α = out · in^α                   │
 * │                                                                 │
 * │   Solving for Δout:                                            │
 * │     Δout = out · (1 - (in / (in + Δin))^α)                     │
 * │                                                                 │
 * │   Update reserves:                                             │
 * │     in' = in + Δin                                             │
 * │     out' = out - Δout                                          │
 * └─────────────────────────────────────────────────────────────────┘
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │ EXACT OUT: Given Δout, compute Δin                             │
 * │                                                                 │
 * │   From invariant preservation:                                 │
 * │     (out - Δout) · (in + Δin)^α = out · in^α                   │
 * │                                                                 │
 * │   Solving for Δin:                                             │
 * │     Δin = in · ((out / (out - Δout))^(1/α) - 1)                │
 * │                                                                 │
 * │   Update reserves:                                             │
 * │     in' = in + Δin                                             │
 * │     out' = out - Δout                                          │
 * └─────────────────────────────────────────────────────────────────┘
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                              FEE REINVESTMENT
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 * The product K_product = in · out after a swap:
 *
 *   K'_product / K_product = (in'/in)^(1-α) = ((in + Δin)/in)^(1-α)
 *
 * For α < 1 (fee > 0) and Δin > 0:
 *   - (1-α) > 0
 *   - (in + Δin)/in > 1
 *   - Therefore K'_product > K_product
 *
 * The pool's liquidity GROWS after every swap, representing reinvested fees.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *                           FEE PARAMETER FORMAT
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *
 * Fee is specified in basis points (bps):
 *   • 1 bps = 0.01%
 *   • 30 bps = 0.3% (typical DEX) → α = 0.997
 *   • 100 bps = 1% → α = 0.99
 *   • Max = 5000 bps = 50% → α = 0.5
 */

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context } from "../libs/VM.sol";
import { StatelessSwapMath } from "../libs/StatelessSwapMath.sol";

/// @title StatelessSwapArgsBuilder - Argument encoding/decoding for StatelessSwap
/// @notice Handles parameter packing and parsing for the invariant curve swap instruction
library StatelessSwapArgsBuilder {
    using SafeCast for uint256;
    using Calldata for bytes;

    error StatelessSwapMissingFee();
    error StatelessSwapFeeExceedsMax(uint32 fee, uint32 max);

    /// @notice Maximum fee in BPS (50% = 5000 bps)
    uint32 internal constant MAX_FEE_BPS = 5000;

    /// @notice Build encoded arguments for StatelessSwap2D instruction
    /// @param feeBps Fee in basis points (e.g., 30 for 0.3%)
    /// @return Encoded bytes for the instruction
    function build2D(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= MAX_FEE_BPS, StatelessSwapFeeExceedsMax(feeBps, MAX_FEE_BPS));
        return abi.encodePacked(feeBps);
    }

    /// @notice Parse encoded arguments for StatelessSwap2D instruction
    /// @param args Encoded arguments
    /// @return feeBps Fee in basis points
    function parse2D(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, StatelessSwapMissingFee.selector)));
    }
}

/// @title StatelessSwap - Invariant curve swap with bidirectional fee reinvestment
/// @notice Implements out·in^α = K curve where α = 1 - fee
/// @dev No state variables - works only with SwapVM registers
/// @dev Fees are automatically reinvested into the pool from both directions
contract StatelessSwap {
    using SafeCast for uint256;
    using Calldata for bytes;

    error StatelessSwapRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);
    error StatelessSwapRecomputeDetected();
    error StatelessSwapInsufficientOutput(uint256 requested, uint256 available);

    /// @notice Execute an invariant curve swap with fee reinvestment
    /// @dev ExactIn:  Δout = out · (1 - (in/(in+Δin))^α)
    /// @dev ExactOut: Δin = in · ((out/(out-Δout))^(1/α) - 1)
    /// @param ctx SwapVM execution context
    /// @param args Encoded [feeBps: uint32]
    function _statelessSwap2D(Context memory ctx, bytes calldata args) internal pure {
        require(
            ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0,
            StatelessSwapRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut)
        );

        uint32 feeBps = StatelessSwapArgsBuilder.parse2D(args);
        
        // Convert fee BPS to alpha: α = 1 - fee
        // feeBps of 30 (0.3%) → alpha = 0.997 * 1e18
        uint256 alpha = StatelessSwapMath.feeToAlpha(feeBps);

        uint256 balanceIn = ctx.swap.balanceIn;
        uint256 balanceOut = ctx.swap.balanceOut;

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, StatelessSwapRecomputeDetected());

            uint256 amountIn = ctx.swap.amountIn;
            
            // Use the invariant curve math to compute output
            ctx.swap.amountOut = StatelessSwapMath.swapExactIn(balanceIn, balanceOut, amountIn, alpha);

        } else {
            require(ctx.swap.amountIn == 0, StatelessSwapRecomputeDetected());

            uint256 amountOut = ctx.swap.amountOut;
            
            require(amountOut < balanceOut, StatelessSwapInsufficientOutput(amountOut, balanceOut));

            // Use the invariant curve math to compute required input
            ctx.swap.amountIn = StatelessSwapMath.swapExactOut(balanceIn, balanceOut, amountOut, alpha);
        }
    }
}
