// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { CubeRoot } from "../libs/CubeRoot.sol";

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
    error ConcentrateParsingMissingLiquidityRoots();
    error ConcentrateParsingMissingLiquidityPowers();

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

    /// @notice Compute priceMin/priceMax from deltas and balances for a pair
    /// @param price Absolute price (use 1e18 for 1:1, or balanceB/balanceA for current)
    function computePriceBounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 deltaA,
        uint256 deltaB,
        uint256 price
    ) public pure returns (uint256 priceMin, uint256 priceMax) {
        // From formula: deltaA = balanceA / (sqrt(price/priceMin) - 1)
        // => sqrt(price/priceMin) = (balanceA + deltaA) / deltaA
        // => priceMin = price * (deltaA / (balanceA + deltaA))²
        uint256 ratioA = deltaA * ONE / (balanceA + deltaA);
        priceMin = price * ratioA / ONE * ratioA / ONE;
        // From formula: deltaB = balanceB / (sqrt(priceMax/price) - 1)
        // => sqrt(priceMax/price) = (balanceB + deltaB) / deltaB
        // => priceMax = price * ((balanceB + deltaB) / deltaB)²
        uint256 ratioB = (balanceB + deltaB) * ONE / deltaB;
        priceMax = price * ratioB / ONE * ratioB / ONE;
    }

    /// @notice Compute all deltas from 3 specific price bounds (one per delta)
    /// @dev Uses priceMinAB for deltaA, priceMaxAB for deltaB, priceMaxAC for deltaC
    /// @param balanceA Initial balance of tokenA
    /// @param balanceB Initial balance of tokenB
    /// @param balanceC Initial balance of tokenC
    /// @param priceAB Absolute price for A/B pair
    /// @param priceAC Absolute price for A/C pair
    /// @param priceBC Absolute price for B/C pair
    /// @param priceMinAB Minimum price for A/B pair (for deltaA)
    /// @param priceMaxAB Maximum price for A/B pair (for deltaB)
    /// @param priceMaxAC Maximum price for A/C pair (for deltaC)
    function computeDeltas3D(
        uint256 balanceA,
        uint256 balanceB,
        uint256 balanceC,
        uint256 priceAB,
        uint256 priceAC,
        uint256 priceBC,
        uint256 priceMinAB,
        uint256 priceMaxAB,
        uint256 priceMaxAC
    ) public pure returns (
        uint256 deltaA,
        uint256 deltaB,
        uint256 deltaC,
        uint256 priceMinAC,
        uint256 priceMinBC,
        uint256 priceMaxBC,
        uint256 liquidityRoot,
        uint256 liquidityPower
    ) {
        // Compute deltaA from priceMinAB
        uint256 sqrtPriceMinAB = Math.sqrt(priceAB * ONE / priceMinAB) * SQRT_ONE;
        deltaA = (priceAB == priceMinAB) ? 0 : (balanceA * ONE / (sqrtPriceMinAB - ONE));

        // Compute deltaB from priceMaxAB
        uint256 sqrtPriceMaxAB = Math.sqrt(priceMaxAB * ONE / priceAB) * SQRT_ONE;
        deltaB = (priceAB == priceMaxAB) ? 0 : (balanceB * ONE / (sqrtPriceMaxAB - ONE));

        // Compute deltaC from priceMaxAC
        uint256 sqrtPriceMaxAC = Math.sqrt(priceMaxAC * ONE / priceAC) * SQRT_ONE;
        deltaC = (priceAC == priceMaxAC) ? 0 : (balanceC * ONE / (sqrtPriceMaxAC - ONE));

        // Compute all price bounds from the deltas
        (priceMinAC,) = computePriceBounds(balanceA, balanceC, deltaA, deltaC, priceAC);
        (priceMinBC, priceMaxBC) = computePriceBounds(balanceB, balanceC, deltaB, deltaC, priceBC);
        liquidityPower = (balanceA + deltaA) * (balanceB + deltaB) * (balanceC + deltaC);
        liquidityRoot = CubeRoot.cbrt(liquidityPower);
    }

    function buildXD(address[] memory tokens, uint256[] memory deltas, uint256 liquidityRoot, uint256 liquidityPower) internal pure returns (bytes memory) {
        require(tokens.length == deltas.length, ConcentrateArraysLengthMismatch(tokens.length, deltas.length));
        bytes memory packed = abi.encodePacked((tokens.length).toUint16());
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, bytes20(tokens[i]));
        }
        return abi.encodePacked(packed, deltas, liquidityRoot, liquidityPower);
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB, uint256 liquidity) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, liquidity);
    }

    function parseXD(bytes calldata args) internal pure returns (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, uint256 liquidityRoot, uint256 liquidityPower) {
        unchecked {
            tokensCount = uint16(bytes2(args.slice(0, 2, ConcentrateParsingMissingTokensCount.selector)));
            uint256 deltasOffset = 2 + 20 * tokensCount;
            uint256 liquidityRootOffset = deltasOffset + 32 * tokensCount; // 1 delta per token
            uint256 liquidityPowerOffset = liquidityRootOffset + 32; // 32 bytes for liquidityRoot and liquidityPower

            tokens = args.slice(2, deltasOffset, ConcentrateParsingMissingTokenAddresses.selector);
            deltas = args.slice(deltasOffset, liquidityRootOffset, ConcentrateParsingMissingDeltas.selector);
            liquidityRoot = uint256(bytes32(args.slice(liquidityRootOffset, liquidityPowerOffset, ConcentrateParsingMissingLiquidityRoots.selector)));
            liquidityPower = uint256(bytes32(args.slice(liquidityPowerOffset, liquidityPowerOffset+32, ConcentrateParsingMissingLiquidityPowers.selector)));
        }
    }

    function parse2D(bytes calldata args, address tokenIn, address tokenOut) internal pure returns (uint256 deltaIn, uint256 deltaOut, uint256 liquidity) {
        uint256 deltaLt = uint256(bytes32(args.slice(0, 32, ConcentrateTwoTokensMissingDeltaLt.selector)));
        uint256 deltaGt = uint256(bytes32(args.slice(32, 64, ConcentrateTwoTokensMissingDeltaGt.selector)));
        (deltaIn, deltaOut) = tokenIn < tokenOut ? (deltaLt, deltaGt) : (deltaGt, deltaLt);
        liquidity = uint256(bytes32(args.slice(64, 96, ConcentrateParsingMissingLiquidityRoots.selector)));
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

    mapping(bytes32 => uint256) public liquidity;

    function concentratedBalance(uint256 balance, uint256 delta, uint256 initialLiquidity, uint256 currentLiquidity) public pure returns (uint256) {
        return currentLiquidity == 0 ? balance + delta : balance + delta * currentLiquidity / initialLiquidity;
    }

    /// @param args.deltaLt | 32 bytes
    /// @param args.deltaGt | 32 bytes
    /// @param args.liquidity | 32 bytes
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        uint256 currentLiquidity = Math.sqrt(liquidity[ctx.query.orderHash]);

        (uint256 deltaIn, uint256 deltaOut, uint256 initialLiquidity) = XYCConcentrateArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaIn, initialLiquidity, currentLiquidity);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOut, initialLiquidity, currentLiquidity);
        ctx.runLoop();
        _updateLiquidity2D(ctx);
    }

    /// @param args.tokensCount | 2 bytes
    /// @param args.tokens[]    | 20 bytes * args.tokensCount
    /// @param args.deltas[]    | 32 bytes * args.tokensCount
    /// @param args.liquidity   | 32 bytes
    function _xycConcentrateGrowLiquidity3D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        uint256 currentLiquidity = liquidity[ctx.query.orderHash];
        uint256 initialLiquidityPower = _prepareBalancesXD(ctx, args, CubeRoot.cbrt(currentLiquidity));
        uint256 concentratedInBefore = ctx.swap.balanceIn;
        uint256 concentratedOutBefore = ctx.swap.balanceOut;

        ctx.runLoop();
        _updateLiquidityXD(ctx, currentLiquidity == 0 ? initialLiquidityPower : currentLiquidity, concentratedInBefore, concentratedOutBefore);
    }

    /// @param args.tokensCount | 2 bytes
    /// @param args.tokens[]    | 20 bytes * args.tokensCount
    /// @param args.deltas[]    | 32 bytes * args.tokensCount
    /// @param args.liquidity   | 32 bytes
    function _xycConcentrateGrowLiquidity4D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        uint256 currentLiquidity = liquidity[ctx.query.orderHash];
        uint256 initialLiquidityPower = _prepareBalancesXD(ctx, args, Math.sqrt(Math.sqrt(currentLiquidity))); // 4th root of liquidity for 4D concentration
        uint256 concentratedInBefore = ctx.swap.balanceIn;
        uint256 concentratedOutBefore = ctx.swap.balanceOut;

        ctx.runLoop();
        _updateLiquidityXD(ctx, currentLiquidity == 0 ? initialLiquidityPower : currentLiquidity, concentratedInBefore, concentratedOutBefore);
    }

    function _prepareBalancesXD(Context memory ctx, bytes calldata args, uint256 currentLiquidity) pure internal returns (uint256) {
        (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, uint256 initialLiquidityRoot, uint256 initialLiquidityPower) = XYCConcentrateArgsBuilder.parseXD(args);
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 delta = uint256(bytes32(deltas.slice(i * 32)));

            if (ctx.query.tokenIn == token) {
                ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, delta, initialLiquidityRoot, currentLiquidity);
            } else if (ctx.query.tokenOut == token) {
                ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, delta, initialLiquidityRoot, currentLiquidity);
            }
        }

        return initialLiquidityPower;
    }

    function _updateLiquidity2D(Context memory ctx) internal {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            liquidity[ctx.query.orderHash] = (ctx.swap.balanceIn + ctx.swap.amountIn) * (ctx.swap.balanceOut - ctx.swap.amountOut);
        }
    }

    function _updateLiquidityXD(
        Context memory ctx,
        uint256 liquidityBefore,
        uint256 concentratedInBefore,
        uint256 concentratedOutBefore
    ) internal {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            uint256 concentratedInAfter = ctx.swap.balanceIn + ctx.swap.amountIn;
            uint256 concentratedOutAfter = ctx.swap.balanceOut - ctx.swap.amountOut;

            liquidity[ctx.query.orderHash] = Math.mulDiv(liquidityBefore, concentratedInAfter*concentratedOutAfter, concentratedInBefore*concentratedOutBefore);
        }
    }
}
