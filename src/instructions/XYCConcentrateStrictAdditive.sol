// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { StrictAdditiveMath } from "../libs/StrictAdditiveMath.sol";

/// @notice Arguments builder for XYCConcentrateStrictAdditive instruction
library XYCConcentrateStrictAdditiveArgsBuilder {
    using Calldata for bytes;

    uint256 internal constant ALPHA_SCALE = StrictAdditiveMath.ALPHA_SCALE;
    uint256 internal constant ONE = 1e18;

    error ConcentrateStrictAdditiveTwoTokensMissingDeltaLt();
    error ConcentrateStrictAdditiveTwoTokensMissingDeltaGt();
    error ConcentrateStrictAdditiveInconsistentPrices(uint256 price, uint256 priceMin, uint256 priceMax);

    /// @notice Compute initial deltas for x^α·y=K concentrated liquidity
    /// @dev For each direction, marginal price at boundary satisfies:
    ///      P_boundary/P_initial = (δ/(balance+δ))^(1+1/α)
    ///      Solving: δ = balance · r / (1 - r),  where r = priceBound^(α/(α+1))
    /// @dev For α=1 (ALPHA_SCALE), degenerates to the standard x·y=k formula:
    ///      r = sqrt(priceBound), matching XYCConcentrateArgsBuilder.computeDeltas
    /// @param balanceA Initial balance of tokenA
    /// @param balanceB Initial balance of tokenB
    /// @param price Current price (tokenB/tokenA with 1e18 precision)
    /// @param priceMin Minimum price for concentration range
    /// @param priceMax Maximum price for concentration range
    /// @param alpha Alpha exponent scaled by ALPHA_SCALE (e.g. 997_000_000 for α=0.997)
    /// @return deltaA Virtual reserve addition for tokenA
    /// @return deltaB Virtual reserve addition for tokenB
    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax,
        uint256 alpha
    ) public pure returns (uint256 deltaA, uint256 deltaB) {
        require(priceMin <= price && price <= priceMax,
            ConcentrateStrictAdditiveInconsistentPrices(price, priceMin, priceMax));

        // Exponent: α/(α+1) where alpha is scaled by ALPHA_SCALE
        // alphaExp = alpha * ALPHA_SCALE / (alpha + ALPHA_SCALE), result in ALPHA_SCALE units
        uint256 alphaExp = alpha * ALPHA_SCALE / (alpha + ALPHA_SCALE);

        if (price != priceMin) {
            // rA = (priceMin/price)^(α/(α+1))
            uint256 rA = StrictAdditiveMath.powRatio(priceMin, price, alphaExp);
            // δA = balanceA · rA / (ONE - rA)
            deltaA = balanceA * rA / (ONE - rA);
        }

        if (price != priceMax) {
            // rB = (priceMax/price)^(α/(α+1))
            uint256 rB = StrictAdditiveMath.powRatio(priceMax, price, alphaExp);
            // δB = balanceB · ONE / (rB - ONE), since rB > ONE
            deltaB = balanceB * ONE / (rB - ONE);
        }
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt);
    }

    function parse2D(
        bytes calldata args,
        address tokenIn,
        address tokenOut
    ) internal pure returns (uint256 deltaIn, uint256 deltaOut) {
        uint256 deltaLt = uint256(bytes32(args.slice(0, 32, ConcentrateStrictAdditiveTwoTokensMissingDeltaLt.selector)));
        uint256 deltaGt = uint256(bytes32(args.slice(32, 64, ConcentrateStrictAdditiveTwoTokensMissingDeltaGt.selector)));
        (deltaIn, deltaOut) = tokenIn < tokenOut ? (deltaLt, deltaGt) : (deltaGt, deltaLt);
    }
}

/// @title XYCConcentrateStrictAdditive - Stateless concentration for x^α·y=K AMM
/// @notice Adds virtual reserves (deltas) to concentrate liquidity, then runs inner swap
contract XYCConcentrateStrictAdditive {
    using Calldata for bytes;
    using ContextLib for Context;

    error ConcentrateStrictAdditiveShouldBeUsedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);

    /// @notice Concentrate liquidity for 2 tokens, then run inner swap instruction(s)
    /// @dev Fixed deltas remain correct across swaps because x^α·y invariant
    ///      is preserved by XYCSwapStrictAdditive formula.
    /// @param ctx The swap context containing balances and amounts
    /// @param args Encoded deltas: deltaLt (32 bytes) + deltaGt (32 bytes)
    function _xycConcentrateStrictAdditive2D(Context memory ctx, bytes calldata args) internal {
        require(
            ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0,
            ConcentrateStrictAdditiveShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut)
        );

        (uint256 deltaIn, uint256 deltaOut) =
            XYCConcentrateStrictAdditiveArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn += deltaIn;
        ctx.swap.balanceOut += deltaOut;

        ctx.runLoop();
    }
}
