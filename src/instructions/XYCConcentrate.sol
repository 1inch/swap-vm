// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;
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
    /// @dev JavaScript implementation:
    ///      ```js
    ///      function computeDeltas(balanceA, balanceB, price, priceMin, priceMax) {
    ///         const sqrtMin = Math.sqrt(price * 1e18 / priceMin);
    ///         const sqrtMax = Math.sqrt(priceMax * 1e18 / price);
    ///         return {
    ///             deltaA: (price == priceMin) ? 0 : (balanceA * 1e18 / (sqrtMin - 1e18)),
    ///             deltaB: (price == priceMax) ? 0 : (balanceB * 1e18 / (sqrtMax - 1e18)),
    ///         };
    ///      }
    ///      ```
    /// @param balanceA Initial balance of tokenA
    /// @param balanceB Initial balance of tokenB
    /// @param price Current price (tokenB/tokenA with 1e18 precision)
    /// @param priceMin Minimum price for concentration range (tokenB/tokenA with 1e18 precision)
    /// @param priceMax Maximum price for concentration range (tokenB/tokenA with 1e18 precision)
    /// @return deltaA Initial balance adjustment for tokenA during A=>B swaps
    /// @return deltaB Initial balance adjustment for tokenB during B=>A swaps
    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity) {
        require(priceMin <= price && price <= priceMax, ConcentrateInconsistentPrices(price, priceMin, priceMax));
        uint256 sqrtPriceMin = Math.sqrt(price * ONE / priceMin) * SQRT_ONE;
        uint256 sqrtPriceMax = Math.sqrt(priceMax * ONE / price) * SQRT_ONE;
        deltaA = (price == priceMin) ? 0 : (balanceA * ONE / (sqrtPriceMin - ONE));
        deltaB = (price == priceMax) ? 0 : (balanceB * ONE / (sqrtPriceMax - ONE));
        liquidity = Math.sqrt((balanceA + deltaA) * (balanceB + deltaB));
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
    function _xycConcentrateGrowPriceRangeXD(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas,) = XYCConcentrateArgsBuilder.parseXD(args);
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 delta = uint256(bytes32(deltas.slice(i * 32)));

            if (ctx.query.tokenIn == token) {
                ctx.swap.balanceIn += delta;
            } else if (ctx.query.tokenOut == token) {
                ctx.swap.balanceOut += delta;
            }
        }
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
    function _xycConcentrateGrowPriceRange2D(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 deltaIn, uint256 deltaOut, ) = XYCConcentrateArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn += deltaIn;
        ctx.swap.balanceOut += deltaOut;
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
