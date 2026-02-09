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

    error ConcentrateArraysLengthMismatch(uint256 tokensLength, uint256 deltasLength, uint256 balancesLength);
    error ConcentrateInconsistentPrices(uint256 price, uint256 priceMin, uint256 priceMax);

    error ConcentrateTwoTokensMissingDeltaLt();
    error ConcentrateTwoTokensMissingDeltaGt();
    error ConcentrateParsingMissingTokensCount();
    error ConcentrateParsingMissingTokenAddresses();
    error ConcentrateParsingMissingDeltas();
    error ConcentrateParsingMissingLiquidities();
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

    function computePairs(address[] memory tokens, uint256[] memory balances, uint256[] memory prices, uint256[] memory priceMins, uint256[] memory priceMaxs) internal pure returns (bytes32[] memory pairIds, uint256[] memory deltas, uint256[] memory liquidities) {
        uint256 n = tokens.length;
        uint256 pairsCount = n * (n - 1) / 2;

        pairIds = new bytes32[](pairsCount);
        deltas = new uint256[](2 * pairsCount);
        liquidities = new uint256[](pairsCount);

        uint256 pairIndex = 0;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                address tokenA = tokens[i];
                address tokenB = tokens[j];

                (address tokenLt, address tokenGt) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

                (uint256 deltaA, uint256 deltaB, uint256 liquidity) = computeDeltas(
                    balances[i],
                    balances[j],
                    prices[pairIndex],
                    priceMins[pairIndex],
                    priceMaxs[pairIndex]
                );

                pairIds[pairIndex] = getPairId(tokenLt, tokenGt);

                (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
                deltas[2 * pairIndex] = deltaLt;
                deltas[2 * pairIndex + 1] = deltaGt;

                liquidities[pairIndex] = liquidity;
                pairIndex++;
            }
        }
    }

    function getPairId(address tokenLt, address tokenGt) internal pure returns (bytes32) {
        return bytes32(uint256(uint128(uint160(tokenLt))) << 128 | uint256(uint128(uint160(tokenGt))));
    }

    function buildXD(bytes32[] memory pairIds, uint256[] memory deltas, uint256[] memory liquidities) internal pure returns (bytes memory) {
        require(2 * pairIds.length == deltas.length && pairIds.length == liquidities.length, ConcentrateArraysLengthMismatch(pairIds.length, deltas.length, liquidities.length));
        bytes memory packed = abi.encodePacked((pairIds.length).toUint16());
        for (uint256 i = 0; i < pairIds.length; i++) {
            packed = abi.encodePacked(packed, pairIds[i]);
        }
        // Pack deltas as uint128 to save space
        for (uint256 i = 0; i < deltas.length; i++) {
            packed = abi.encodePacked(packed, deltas[i].toUint128());
        }
        // Pack liquidities as uint128 to save space
        for (uint256 i = 0; i < liquidities.length; i++) {
            packed = abi.encodePacked(packed, liquidities[i].toUint128());
        }
        return packed;
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB, uint256 liquidity) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, liquidity);
    }

    function parseXD(bytes calldata args) internal pure returns (uint256 pairsCount, bytes calldata pairIds, bytes calldata deltas, bytes calldata liquidities) {
        unchecked {
            pairsCount = uint16(bytes2(args.slice(0, 2, ConcentrateParsingMissingTokensCount.selector)));
            uint256 deltasOffset = 2 + 32 * pairsCount;
            uint256 liquiditiesOffset = deltasOffset + 16 * pairsCount * 2; // 2 deltas per pair
            uint256 endOffset = liquiditiesOffset + 16 * pairsCount;

            pairIds = args.slice(2, deltasOffset, ConcentrateParsingMissingTokenAddresses.selector);
            deltas = args.slice(deltasOffset, liquiditiesOffset, ConcentrateParsingMissingDeltas.selector);
            liquidities = args.slice(liquiditiesOffset, endOffset, ConcentrateParsingMissingLiquidities.selector);
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

    mapping(bytes32 => mapping(bytes32 => uint256)) public liquidity;
    mapping(bytes32 => mapping(bytes32 => mapping(bytes16 => uint256))) public deltas;

    function concentratedBalance(uint256 balance, uint256 delta, uint256 initialLiquidity, uint256 currentLiquidity) public pure returns (uint256) {
        return currentLiquidity == 0 ? balance + delta : balance + delta * currentLiquidity / initialLiquidity;
    }

    /// @dev Extracts bytes16 token identifier from address
    /// @param token The token address
    /// @return Token identifier (lower 16 bytes of address)
    function _getTokenId(address token) internal pure returns (bytes16) {
        return bytes16(uint128(uint160(token)));
    }

    /// @dev Gets delta from storage if available, otherwise from calldata
    /// @param orderHash The order hash
    /// @param pairId The pair identifier
    /// @param token The token address
    /// @param deltaFromCalldata Delta value from calldata as fallback
    /// @return Actual delta to use (from storage or calldata)
    function _getDelta(
        bytes32 orderHash,
        bytes32 pairId,
        address token,
        uint256 deltaFromCalldata
    ) internal view returns (uint256) {
        bytes16 tokenId = _getTokenId(token);
        uint256 storedDelta = deltas[orderHash][pairId][tokenId];
        return storedDelta > 0 ? storedDelta : deltaFromCalldata;
    }

    /// @dev Stores delta in storage for future use
    /// @param orderHash The order hash
    /// @param pairId The pair identifier
    /// @param token The token address
    /// @param delta The delta value to store
    function _setDelta(
        bytes32 orderHash,
        bytes32 pairId,
        address token,
        uint256 delta
    ) internal {
        bytes16 tokenId = _getTokenId(token);
        deltas[orderHash][pairId][tokenId] = delta;
    }

    /// @dev Returns positions of the tokenIn and tokenOut in the pair (1 for first token, 2 for second token, 0 if not in pair)
    /// @param tokenIn The input token address to check
    /// @param tokenOut The output token address to check
    /// @param pairId The pairId encoding the two tokens in the pair
    /// @return tokenInPosition Position of tokenIn in the pair
    /// @return tokenOutPosition Position of tokenOut in the pair
    function _tokenPositionInPair(address tokenIn, address tokenOut,bytes32 pairId) internal pure returns (uint256, uint256) {
        bytes16 tokenFirstInPair = bytes16(pairId);
        bytes16 tokenLastInPair = bytes16(uint128(uint256(pairId)));
        bytes16 tokenInTail = bytes16(uint128(uint160(tokenIn)));
        bytes16 tokenOutTail = bytes16(uint128(uint160(tokenOut)));
        return (
            tokenFirstInPair == tokenInTail ? 1 : tokenLastInPair == tokenInTail ? 2 : 0,
            tokenFirstInPair == tokenOutTail ? 1 : tokenLastInPair == tokenOutTail ? 2 : 0
        );
    }

    /// @param args.pairsCount | 2 bytes
    /// @param args.pairIds[]  | 32 bytes * args.pairsCount
    /// @param args.deltas[]   | 16 bytes * args.pairsCount * 2
    /// @param args.liquidities[] | 16 bytes * args.pairsCount
    function _xycConcentrateGrowLiquidityXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (address tokenLt, address tokenGt) = ctx.query.tokenIn < ctx.query.tokenOut ? (ctx.query.tokenIn, ctx.query.tokenOut) : (ctx.query.tokenOut, ctx.query.tokenIn);
        bytes32 currentPairId = XYCConcentrateArgsBuilder.getPairId(tokenLt, tokenGt);

        (uint256 pairsCount, bytes calldata pairIds, bytes calldata deltasCd, bytes calldata liquidities) = XYCConcentrateArgsBuilder.parseXD(args);
        for (uint256 i = 0; i < pairsCount; i++) {
            bytes32 pairId = bytes32(pairIds.slice(i * 32));
            if (currentPairId == pairId) {
                uint256 initialLiquidity = uint128(bytes16(liquidities.slice(i * 16)));
                uint256 currentLiquidity = Math.sqrt(liquidity[ctx.query.orderHash][currentPairId]);

                uint256 deltaLtCd = uint128(bytes16(deltasCd.slice(i * 32)));
                uint256 deltaGtCd = uint128(bytes16(deltasCd.slice(i * 32 + 16)));

                // Get actual deltas (from storage if updated, otherwise from calldata)
                uint256 deltaLt = _getDelta(ctx.query.orderHash, currentPairId, tokenLt, deltaLtCd);
                uint256 deltaGt = _getDelta(ctx.query.orderHash, currentPairId, tokenGt, deltaGtCd);
                uint256 balanceInBefore = ctx.swap.balanceIn;
                uint256 balanceOutBefore = ctx.swap.balanceOut;

                ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, ctx.query.tokenIn == tokenLt ? deltaLt : deltaGt, initialLiquidity, currentLiquidity);
                ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, ctx.query.tokenOut == tokenLt ? deltaLt : deltaGt, initialLiquidity, currentLiquidity);
                ctx.runLoop();
                _updateLiquidity(ctx, balanceInBefore, balanceOutBefore, pairId, pairsCount, pairIds, deltasCd, liquidities);

                break;
            }
        }
    }

    /// @param args.deltaLt | 32 bytes
    /// @param args.deltaGt | 32 bytes
    /// @param args.liquidity | 32 bytes
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (address tokenLt, address tokenGt) = ctx.query.tokenIn < ctx.query.tokenOut ? (ctx.query.tokenIn, ctx.query.tokenOut) : (ctx.query.tokenOut, ctx.query.tokenIn);
        bytes32 pairId = XYCConcentrateArgsBuilder.getPairId(tokenLt, tokenGt);
        uint256 currentLiquidity = Math.sqrt(liquidity[ctx.query.orderHash][pairId]);

        (uint256 deltaInCd, uint256 deltaOutCd, uint256 initialLiquidity) = XYCConcentrateArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaInCd, initialLiquidity, currentLiquidity);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOutCd, initialLiquidity, currentLiquidity);

        ctx.runLoop();
        _updateLiquidity(ctx, pairId);
    }

    function _updateLiquidity(Context memory ctx, bytes32 pairId) internal {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            liquidity[ctx.query.orderHash][pairId] = (ctx.swap.balanceIn + ctx.swap.amountIn) * (ctx.swap.balanceOut - ctx.swap.amountOut);
        }
    }

    function _updateLiquidity(
        Context memory ctx,
        uint256 balanceInBefore,
        uint256 balanceOutBefore,
        bytes32 pairId,
        uint256 pairsCount,
        bytes calldata pairIds,
        bytes calldata deltasCd,
        bytes calldata liquidities
    ) private {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            liquidity[ctx.query.orderHash][pairId] = (ctx.swap.balanceIn + ctx.swap.amountIn) * (ctx.swap.balanceOut - ctx.swap.amountOut);

            for (uint256 i = 0; i < pairsCount; i++) {
                bytes32 pairIdAffected = bytes32(pairIds.slice(i * 32));
                if (pairIdAffected == pairId) continue;

                (uint256 tokenInPosition, uint256 tokenOutPosition) = _tokenPositionInPair(ctx.query.tokenIn, ctx.query.tokenOut, pairIdAffected);

                if (tokenInPosition > 0) {
                    _updateLiquidityForPair(
                        ctx,
                        ctx.query.tokenIn,
                        pairIdAffected,
                        balanceInBefore,
                        uint128(bytes16(deltasCd.slice(tokenInPosition == 1 ? i * 32 : i * 32 + 16))),
                        uint128(bytes16(liquidities.slice(i * 16))),
                        ctx.swap.amountIn
                    );
                } else if (tokenOutPosition > 0) {
                    _updateLiquidityForPair(
                        ctx,
                        ctx.query.tokenOut,
                        pairIdAffected,
                        balanceOutBefore,
                        uint128(bytes16(deltasCd.slice(tokenOutPosition == 1 ? i * 32 : i * 32 + 16))),
                        uint128(bytes16(liquidities.slice(i * 16))),
                        ctx.swap.amountOut
                    );
                }
            }
        }
    }

    /// @dev Updates liquidity for a specific pair when one of its tokens' balance changes.
    /// This is necessary to maintain accurate liquidity values across multiple pairs sharing tokens.
    /// Recalculates delta as if the pool was initialized with the new balance
    function _updateLiquidityForPair(
        Context memory ctx,
        address tokenChanged,
        bytes32 pairId,
        uint256 balanceBefore,
        uint256 deltaFromCalldata,
        uint256 initialLiquidity,
        uint256 amount
    ) internal {
        // Calculate new physical balance after swap
        uint256 balanceAfter = ctx.query.tokenIn == tokenChanged ? balanceBefore + amount : balanceBefore - amount;

        // Recalculate delta as if pool initialized with new balance
        // delta_new = delta_old * (balance_after / balance_before)
        // This maintains: delta_old / balance_before = delta_new / balance_after
        uint256 newDelta = balanceBefore > 0 ? deltaFromCalldata * balanceAfter / balanceBefore : deltaFromCalldata;

        // Store updated delta in storage for future use
        _setDelta(ctx.query.orderHash, pairId, tokenChanged, newDelta);

        // Update liquidity using the NEW delta
        uint256 currentLiquidity = liquidity[ctx.query.orderHash][pairId];
        uint256 balanceConcentratedBefore = concentratedBalance(balanceBefore, deltaFromCalldata, initialLiquidity, Math.sqrt(currentLiquidity));
        uint256 balanceConcentratedAfter = concentratedBalance(balanceAfter, newDelta, initialLiquidity, Math.sqrt(currentLiquidity));
        currentLiquidity = currentLiquidity == 0 ? initialLiquidity * initialLiquidity : currentLiquidity;
        liquidity[ctx.query.orderHash][pairId] = currentLiquidity * balanceConcentratedAfter / balanceConcentratedBefore;
    }
}
