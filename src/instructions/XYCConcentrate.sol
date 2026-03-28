// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

/// @dev Fixed-point basis for sqrt price values (1e18)
uint256 constant ONE = 1e18;

library XYCConcentrateArgsBuilder {
    using Calldata for bytes;

    error ConcentrateInvalidPriceBounds(uint256 sqrtPriceMin, uint256 sqrtPriceMax);
    error ConcentrateMissingSqrtPriceMin();
    error ConcentrateMissingSqrtPriceMax();

    /// @notice Build args for the 2D price-bounds concentrate instruction
    /// @param sqrtPriceMin sqrt(P_min) in 1e18 fixed-point, where P = tokenGt/tokenLt
    /// @param sqrtPriceMax sqrt(P_max) in 1e18 fixed-point, where P = tokenGt/tokenLt
    function build2D(uint256 sqrtPriceMin, uint256 sqrtPriceMax) internal pure returns (bytes memory) {
        require(0 < sqrtPriceMin && sqrtPriceMin < sqrtPriceMax, ConcentrateInvalidPriceBounds(sqrtPriceMin, sqrtPriceMax));
        return abi.encodePacked(sqrtPriceMin, sqrtPriceMax);
    }

    function parse2D(bytes calldata args) internal pure returns (uint256 sqrtPriceMin, uint256 sqrtPriceMax) {
        sqrtPriceMin = uint256(bytes32(args.slice(0, 32, ConcentrateMissingSqrtPriceMin.selector)));
        sqrtPriceMax = uint256(bytes32(args.slice(32, 64, ConcentrateMissingSqrtPriceMax.selector)));
    }

    /// @notice Compute the implied spot price and liquidity from real balances and price bounds
    /// @param balanceLt Real balance of the token with lower address
    /// @param balanceGt Real balance of the token with higher address
    /// @param sqrtPriceMin sqrt(P_min) in 1e18 fixed-point
    /// @param sqrtPriceMax sqrt(P_max) in 1e18 fixed-point
    /// @return liquidity The computed L value
    /// @return sqrtPriceSpot The implied sqrt(P_spot) in 1e18 fixed-point
    function computeLiquidityAndPrice(
        uint256 balanceLt,
        uint256 balanceGt,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256 liquidity, uint256 sqrtPriceSpot) {
        liquidity = _computeL(balanceLt, balanceGt, sqrtPriceMin, sqrtPriceMax);
        uint256 virtualLt = balanceLt + Math.mulDiv(liquidity, ONE, sqrtPriceMax);
        uint256 virtualGt = balanceGt + Math.mulDiv(liquidity, sqrtPriceMin, ONE);
        sqrtPriceSpot = Math.sqrt(Math.mulDiv(virtualGt, ONE*ONE, virtualLt));
    }

    /// @notice Compute the initial balances for given L, P_spot, P_min, P_max:
    ///   bLt = L * (sqrtPmax - sqrtPspot) / (sqrtPmax * sqrtPspot)
    ///   bGt = L * (sqrtPspot - sqrtPmin)
    function computeBalances(
        uint256 targetL,
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal pure returns (uint256 bLt, uint256 bGt) {
        require(sqrtPmin < sqrtPmax, ConcentrateInvalidPriceBounds(sqrtPmin, sqrtPmax));

        uint256 invSqrtPspot = Math.mulDiv(ONE, ONE, sqrtPspot);
        uint256 invSqrtPmax = Math.mulDiv(ONE, ONE, sqrtPmax);

        // Handle boundary: if sqrtPspot >= sqrtPmax, bLt = 0
        bLt = invSqrtPspot > invSqrtPmax ? Math.mulDiv(targetL, invSqrtPspot - invSqrtPmax, ONE) : 0;
        // Handle boundary: if sqrtPspot <= sqrtPmin, bGt = 0
        bGt = sqrtPspot > sqrtPmin ? Math.mulDiv(targetL, sqrtPspot - sqrtPmin, ONE) : 0;
    }

    /// @notice Compute max achievable L from available token amounts at a given spot price.
    ///   Takes the minimum of L implied by each token.
    /// @return targetL  The max achievable L
    /// @return actualLt Amount of tokenLt actually needed (<=availableLt)
    /// @return actualGt Amount of tokenGt actually needed (<=availableGt)
    function computeLiquidityFromAmounts(
        uint256 availableLt,
        uint256 availableGt,
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal pure returns (uint256 targetL, uint256 actualLt, uint256 actualGt) {
        require(sqrtPmin < sqrtPmax, ConcentrateInvalidPriceBounds(sqrtPmin, sqrtPmax));

        uint256 lFromLt = (sqrtPmax > sqrtPspot)
            ? Math.mulDiv(availableLt, Math.mulDiv(sqrtPmax, sqrtPspot, ONE), sqrtPmax - sqrtPspot)
            : type(uint256).max;
        uint256 lFromGt = (sqrtPspot > sqrtPmin)
            ? Math.mulDiv(availableGt, ONE, sqrtPspot - sqrtPmin)
            : type(uint256).max;
        targetL = lFromLt < lFromGt ? lFromLt : lFromGt;
        (actualLt, actualGt) = computeBalances(targetL, sqrtPspot, sqrtPmin, sqrtPmax);
    }

    /// @notice Compute L from real balances and price bounds (internal)
    function _computeL(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256) {
        uint256 alpha = ONE - Math.mulDiv(sqrtPriceMin, ONE, sqrtPriceMax);
        uint256 beta  = Math.mulDiv(bLt, sqrtPriceMin, ONE) + Math.mulDiv(bGt, ONE, sqrtPriceMax);
        uint256 fourAC = Math.mulDiv(4 * alpha, bLt, ONE) * bGt;
        uint256 disc   = beta * beta + fourAC;
        return Math.mulDiv(beta + Math.sqrt(disc), ONE, 2 * alpha);
    }
}

/// @title XYCConcentrate - Concentrated liquidity with price bounds (2-token only)
/// @notice Computes virtual reserves from current real balances and price bounds.
///         L (liquidity) is recomputed from real balances each swap.
///         Fee reinvestment happens automatically as growing real balances increase L.
contract XYCConcentrate {
    using Math for uint256;
    using ContextLib for Context;

    error ConcentrateShouldBeUsedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);

    /// @param args.sqrtPriceMin | 32 bytes (uint256, 1e18 fp) — sqrt(P_min) where P = tokenGt/tokenLt
    /// @param args.sqrtPriceMax | 32 bytes (uint256, 1e18 fp) — sqrt(P_max) where P = tokenGt/tokenLt
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
        require(
            ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0,
            ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut)
        );

        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = XYCConcentrateArgsBuilder.parse2D(args);

        bool isTokenInLt = ctx.query.tokenIn < ctx.query.tokenOut;
        uint256 bLt = isTokenInLt ? ctx.swap.balanceIn : ctx.swap.balanceOut;
        uint256 bGt = isTokenInLt ? ctx.swap.balanceOut : ctx.swap.balanceIn;

        uint256 L = XYCConcentrateArgsBuilder._computeL(bLt, bGt, sqrtPriceMin, sqrtPriceMax);

        if (isTokenInLt) {
            ctx.swap.balanceIn += Math.ceilDiv(L * ONE, sqrtPriceMax);
            ctx.swap.balanceOut += Math.mulDiv(L, sqrtPriceMin, ONE);
        } else {
            ctx.swap.balanceIn += Math.ceilDiv(L * sqrtPriceMin, ONE);
            ctx.swap.balanceOut += Math.mulDiv(L, ONE, sqrtPriceMax);
        }

        ctx.runLoop();
    }
}
