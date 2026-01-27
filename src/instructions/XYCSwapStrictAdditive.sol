// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { StrictAdditiveMath } from "../libs/StrictAdditiveMath.sol";

/// @notice Arguments builder for XYCSwapStrictAdditive instruction
library XYCSwapStrictAdditiveArgsBuilder {
    using Calldata for bytes;

    error XYCSwapStrictAdditiveAlphaOutOfRange(uint256 alpha);
    error XYCSwapStrictAdditiveMissingAlpha();

    uint256 internal constant ALPHA_SCALE = StrictAdditiveMath.ALPHA_SCALE;

    /// @notice Build args for the strict additive swap instruction
    /// @param alpha The alpha exponent scaled by 1e9 (e.g., 997_000_000 for α=0.997)
    /// @dev Alpha must be in range (0, 1e9] where 1e9 = 1.0 (no fee, standard x*y=k)
    /// @dev Lower alpha means higher fee reinvested into pricing
    /// @dev Common values: 0.997e9 (0.3% effective fee), 0.99e9 (1% effective fee)
    function build(uint32 alpha) internal pure returns (bytes memory) {
        require(alpha > 0 && alpha <= ALPHA_SCALE, XYCSwapStrictAdditiveAlphaOutOfRange(alpha));
        return abi.encodePacked(alpha);
    }

    function parse(bytes calldata args) internal pure returns (uint32 alpha) {
        alpha = uint32(bytes4(args.slice(0, 4, XYCSwapStrictAdditiveMissingAlpha.selector)));
    }
}

/// @title XYCSwapStrictAdditive - AMM with strict additive fee reinvested inside pricing
/// @notice Implements x^α * y = K constant function market maker
/// @dev Based on the paper "Strict-Additive Fees Reinvested Inside Pricing for AMMs"
/// @dev Key properties:
///   - Full input credit: x' = x + Δx (all input goes to reserve)
///   - Fees reinvested inside pricing (no external fee bucket)
///   - Strict additivity: swap(a+b) = swap(b) ∘ swap(a) (split invariance)
/// @dev The parameter α controls the fee:
///   - α = 1.0: No fee, standard x*y=k
///   - α < 1.0: Fee is reinvested, lowering output for same input
///   - Lower α = higher effective fee
/// @dev Mathematical formulas (TWO CURVES design - both strictly additive):
    ///   - X→Y direction uses curve: K = y * x^α (power on input token X)
    ///   - Y→X direction uses curve: K = x * y^α (power on input token Y)
    ///   - ExactIn:  Δy = y * (1 - (x / (x + Δx))^α)
    ///   - ExactOut: Δx = x * ((y / (y - Δy))^(1/α) - 1)  [inverse on same curve]
contract XYCSwapStrictAdditive {
    using ContextLib for Context;

    error XYCSwapStrictAdditiveRecomputeDetected();
    error XYCSwapStrictAdditiveRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);

    /// @notice Execute strict additive swap using x^α * y = K formula
    /// @dev Instruction suffix XD: Dynamic args from program, supports both ExactIn and ExactOut
    /// @param ctx The swap context containing balances and amounts
    /// @param args Encoded alpha parameter (4 bytes, uint32 scaled by 1e9)
    /// @dev Uses balanceIn and balanceOut from ctx.swap which should be set by Balances instruction
    ///
    /// ╔═══════════════════════════════════════════════════════════════════════════════════════╗
    /// ║  STRICT ADDITIVE FEE WITH REINVESTMENT INSIDE PRICING (TWO CURVES)                   ║
    /// ║                                                                                       ║
    /// ║  Two Curves Design (both ExactIn and ExactOut strictly additive):                    ║
    /// ║    - X→Y direction: K = y * x^α  (power on input token X)                            ║
    /// ║    - Y→X direction: K = x * y^α  (power on input token Y)                            ║
    /// ║                                                                                       ║
    /// ║  ExactIn:  Δy = y * (1 - (x / (x + Δx))^α)                                           ║
    /// ║  ExactOut: Δx = x * ((y / (y - Δy))^(1/α) - 1)  [inverse on same curve]             ║
    /// ║                                                                                       ║
    /// ║  Properties:                                                                          ║
    /// ║    - BOTH ExactIn and ExactOut are strictly additive                                 ║
    /// ║    - Round trip costs trader (real bid-ask spread for economic incentive)            ║
    /// ║    - Full input credit (all input goes to reserve)                                   ║
    /// ║    - Fee reinvested inside pricing (no external bucket)                              ║
    /// ║                                                                                       ║
    /// ║  Alpha parameter guide:                                                               ║
    /// ║    - α = 1.000 (1e9): No fee, standard constant product                              ║
    /// ║    - α = 0.997 (997e6): ~0.3% equivalent fee                                          ║
    /// ║    - α = 0.990 (990e6): ~1% equivalent fee                                            ║
    /// ║    - α = 0.950 (950e6): ~5% equivalent fee                                            ║
    /// ╚═══════════════════════════════════════════════════════════════════════════════════════╝
    function _xycSwapStrictAdditiveXD(Context memory ctx, bytes calldata args) internal pure {
        require(
            ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0,
            XYCSwapStrictAdditiveRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut)
        );

        uint256 alpha = XYCSwapStrictAdditiveArgsBuilder.parse(args);

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, XYCSwapStrictAdditiveRecomputeDetected());

            // 0 < α <= 1
            // Δy = y * (1 - (x / (x + Δx))^α)
            // Floor division for tokenOut is desired behavior (protects maker)
            ctx.swap.amountOut = StrictAdditiveMath.calcExactIn(
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                ctx.swap.amountIn,
                alpha
            );
        } else {
            require(ctx.swap.amountIn == 0, XYCSwapStrictAdditiveRecomputeDetected());

            // ExactOut: use inverse formula on the SAME curve (strictly additive)
            // Δx = x * ((y / (y - Δy))^(1/α) - 1)
            // Ceiling division for tokenIn is desired behavior (protects maker)
            ctx.swap.amountIn = StrictAdditiveMath.calcExactOut(
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                ctx.swap.amountOut,
                alpha
            );
        }
    }
}
