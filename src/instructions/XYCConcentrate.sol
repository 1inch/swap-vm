// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant ONE = 1e18;
uint256 constant SQRT_ONE = 1e9;

library XYCConcentrateArgsBuilder {
    using SafeCast for uint256;
    using Calldata for bytes;

    error ConcentrateArraysLengthMismatch(uint256 tokensLength, uint256 deltasLength);
    error ConcentrateInconsistentPrices(uint256 price, uint256 priceMin, uint256 priceMax);

    error ConcentrateTwoTokensMissingDeltaLt();
    error ConcentrateTwoTokensMissingDeltaGt();
    error ConcentrateParsingMissingTokensCount();
    error ConcentrateParsingMissingTokenAddresses();
    error ConcentrateParsingMissingDeltas();
    error ConcentrateParsingMissingLiquidity();

    /// @notice Compute initial balance adjustments to achieve concentration within price bounds
    /// @dev Derives the implied spot price from (balanceA, balanceB, priceMin, priceMax) via
    ///      the concentrated-liquidity quadratic, then computes deltas as L/√priceMax and L·√priceMin.
    ///      This ensures exact price-boundary compliance: real balances deplete exactly at priceMin/priceMax.
    ///
    ///      The quadratic solved is:  bx·u² + u·(by/√Phi - bx·√Plo) - by = 0,  where u = √Pspot.
    ///      Then:  L = by/(u - √Plo),  deltaA = L/√Phi,  deltaB = L·√Plo.
    /// @param balanceA Initial balance of tokenA (base token)
    /// @param balanceB Initial balance of tokenB (quote token)
    /// @param priceMin Minimum price for concentration range (tokenB/tokenA with 1e18 precision)
    /// @param priceMax Maximum price for concentration range (tokenB/tokenA with 1e18 precision)
    /// @return deltaA Virtual offset for tokenA
    /// @return deltaB Virtual offset for tokenB
    /// @return liquidity Concentrated liquidity L
    /// @return impliedPrice The spot price implied by the balances and bounds (1e18 precision)
    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity, uint256 impliedPrice) {
        require(priceMin < priceMax, ConcentrateInconsistentPrices(0, priceMin, priceMax));

        uint256 sqrtPlo = Math.sqrt(priceMin * ONE);
        uint256 sqrtPhi = Math.sqrt(priceMax * ONE);

        uint256 sqrtP;
        if (balanceA == 0) {
            sqrtP = sqrtPhi;
        } else if (balanceB == 0) {
            sqrtP = sqrtPlo;
        } else {
            uint256 term1 = Math.mulDiv(balanceA, sqrtPlo, ONE);
            uint256 term2 = Math.mulDiv(balanceB, ONE, sqrtPhi);

            uint256 sqrtDisc;
            if (term1 >= term2) {
                uint256 diff = term1 - term2;
                sqrtDisc = Math.sqrt(diff * diff + 4 * balanceA * balanceB);
                sqrtP = Math.mulDiv(ONE, diff + sqrtDisc, 2 * balanceA);
            } else {
                uint256 diff = term2 - term1;
                sqrtDisc = Math.sqrt(diff * diff + 4 * balanceA * balanceB);
                sqrtP = Math.mulDiv(ONE, sqrtDisc - diff, 2 * balanceA);
            }
        }

        impliedPrice = Math.mulDiv(sqrtP, sqrtP, ONE);

        uint256 L;
        if (sqrtP > sqrtPlo && balanceB > 0) {
            L = Math.mulDiv(balanceB, ONE, sqrtP - sqrtPlo);
        } else if (sqrtP < sqrtPhi && balanceA > 0) {
            uint256 sqrtProduct = Math.mulDiv(sqrtP, sqrtPhi, ONE);
            L = Math.mulDiv(balanceA, sqrtProduct, sqrtPhi - sqrtP);
        }

        deltaA = Math.mulDiv(L, ONE, sqrtPhi);
        deltaB = Math.mulDiv(L, sqrtPlo, ONE);
        liquidity = L;
    }

    /// @notice Backward-compatible wrapper that ignores the price parameter and derives it instead
    /// @dev Existing callers can continue using this signature; price is silently discarded.
    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256, /* price — ignored, derived from balances and bounds */
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity) {
        (deltaA, deltaB, liquidity, ) = computeDeltas(balanceA, balanceB, priceMin, priceMax);
    }

    function buildXD(address[] memory tokens, uint256[] memory deltas, uint256 liquidity) internal pure returns (bytes memory) {
        require(tokens.length == deltas.length, ConcentrateArraysLengthMismatch(tokens.length, deltas.length));
        bytes memory packed = abi.encodePacked((tokens.length).toUint16());
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, tokens[i]);
        }
        return abi.encodePacked(packed, deltas, liquidity);
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB, uint256 liquidity) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, liquidity);
    }

    function parseXD(bytes calldata args) internal pure returns (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, uint256 liquidity) {
        unchecked {
            tokensCount = uint16(bytes2(args.slice(0, 2, ConcentrateParsingMissingTokensCount.selector)));
            uint256 balancesOffset = 2 + 20 * tokensCount;
            uint256 subargsOffset = balancesOffset + 32 * tokensCount;

            tokens = args.slice(2, balancesOffset, ConcentrateParsingMissingTokenAddresses.selector);
            deltas = args.slice(balancesOffset, subargsOffset, ConcentrateParsingMissingDeltas.selector);
            liquidity = uint256(bytes32(args.slice(subargsOffset, subargsOffset + 32, ConcentrateParsingMissingLiquidity.selector)));
        }
    }

    function parse2D(bytes calldata args, address tokenIn, address tokenOut) internal pure returns (uint256 deltaIn, uint256 deltaOut, uint256 liquidity) {
        uint256 deltaLt = uint256(bytes32(args.slice(0, 32, ConcentrateTwoTokensMissingDeltaLt.selector)));
        uint256 deltaGt = uint256(bytes32(args.slice(32, 64, ConcentrateTwoTokensMissingDeltaGt.selector)));
        (deltaIn, deltaOut) = tokenIn < tokenOut ? (deltaLt, deltaGt) : (deltaGt, deltaLt);
        liquidity = uint256(bytes32(args.slice(64, 96, ConcentrateParsingMissingLiquidity.selector)));
    }
}

/// @dev Scales both balanceIn/Out to concentrate liquidity within price bounds for XYCSwap formula,
/// real balances should be drained when price comes to the concentration bounds
contract XYCConcentrate {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Calldata for bytes;
    using ContextLib for Context;

    error ConcentrateShouldBeUsedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);
    error ConcentrateExpectedSwapAmountComputationAfterRunLoop(uint256 amountIn, uint256 amountOut);

    mapping(bytes32 orderHash => uint256) public liquidity;

    function concentratedBalance(bytes32 orderHash, uint256 balance, uint256 delta, uint256 initialLiquidity) public view returns (uint256) {
        uint256 currentLiquidity = liquidity[orderHash];
        return currentLiquidity == 0 ? balance + delta : balance + delta * currentLiquidity / initialLiquidity;
    }

    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]  | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _xycConcentrateGrowLiquidityXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, uint256 initialLiquidity) = XYCConcentrateArgsBuilder.parseXD(args);
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 delta = uint256(bytes32(deltas.slice(i * 32)));

            if (ctx.query.tokenIn == token) {
                ctx.swap.balanceIn = concentratedBalance(ctx.query.orderHash, ctx.swap.balanceIn, delta, initialLiquidity);
            } else if (ctx.query.tokenOut == token) {
                ctx.swap.balanceOut = concentratedBalance(ctx.query.orderHash, ctx.swap.balanceOut, delta, initialLiquidity);
            }
        }

        ctx.runLoop();
        _updateScales(ctx);
    }

    /// @param args.deltaLt | 32 bytes
    /// @param args.deltaGt | 32 bytes
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 deltaIn, uint256 deltaOut, uint256 initialLiquidity) = XYCConcentrateArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn = concentratedBalance(ctx.query.orderHash, ctx.swap.balanceIn, deltaIn, initialLiquidity);
        ctx.swap.balanceOut = concentratedBalance(ctx.query.orderHash, ctx.swap.balanceOut, deltaOut, initialLiquidity);

        ctx.runLoop();
        _updateScales(ctx);
    }

    function _updateScales(Context memory ctx) private {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            // New invariant (after swap)
            uint256 newInv = (ctx.swap.balanceIn + ctx.swap.amountIn) * (ctx.swap.balanceOut - ctx.swap.amountOut);
            liquidity[ctx.query.orderHash] = Math.sqrt(newInv);
        }
    }
}
