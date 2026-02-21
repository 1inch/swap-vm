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
    error ConcentrateParsingMissingInitialBalances();

    /// @notice Compute initial balance adjustments to achieve concentration within price bounds
    /// @dev JavaScript implementation:
    ///      ```js
    ///      function computeDeltas(balanceA, balanceB, price, priceMin, priceMax) {
    ///         const sqrtRatioA = Math.sqrt(priceMax * 1e18 / price);
    ///         const sqrtRatioB = Math.sqrt(price * 1e18 / priceMin);
    ///         return {
    ///             deltaA: (price == priceMax) ? 0 : (balanceA * 1e18 / (sqrtRatioA - 1e18)),
    ///             deltaB: (price == priceMin) ? 0 : (balanceB * 1e18 / (sqrtRatioB - 1e18)),
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
        uint256 sqrtPriceRatioA = Math.sqrt(priceMax * ONE / price) * SQRT_ONE;
        uint256 sqrtPriceRatioB = Math.sqrt(price * ONE / priceMin) * SQRT_ONE;
        deltaA = (price == priceMax) ? 0 : (balanceA * ONE / (sqrtPriceRatioA - ONE));
        deltaB = (price == priceMin) ? 0 : (balanceB * ONE / (sqrtPriceRatioB - ONE));
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
        // From formula: deltaA = balanceA / (sqrt(priceMax/price) - 1)
        // => sqrt(priceMax/price) = (balanceA + deltaA) / deltaA
        // => priceMax = price * ((balanceA + deltaA) / deltaA)²
        uint256 ratioA = (balanceA + deltaA) * ONE / deltaA;
        priceMax = price * ratioA / ONE * ratioA / ONE;
        // From formula: deltaB = balanceB / (sqrt(price/priceMin) - 1)
        // => sqrt(price/priceMin) = (balanceB + deltaB) / deltaB
        // => priceMin = price * (deltaB / (balanceB + deltaB))²
        uint256 ratioB = deltaB * ONE / (balanceB + deltaB);
        priceMin = price * ratioB / ONE * ratioB / ONE;
    }

    /// @notice Compute all deltas from 3 specific price bounds (one per delta)
    /// @dev Uses priceMaxAB for deltaA, priceMinAB for deltaB, priceMaxAC for deltaC
    /// @param balanceA Initial balance of tokenA
    /// @param balanceB Initial balance of tokenB
    /// @param balanceC Initial balance of tokenC
    /// @param priceAB Absolute price for A/B pair
    /// @param priceAC Absolute price for A/C pair
    /// @param priceBC Absolute price for B/C pair
    /// @param priceMinAB Minimum price for A/B pair (for deltaB)
    /// @param priceMaxAB Maximum price for A/B pair (for deltaA)
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
        uint256 concentratedA,
        uint256 concentratedB,
        uint256 concentratedC,
        uint256 priceMinAC,
        uint256 priceMinBC,
        uint256 priceMaxBC,
        uint256 liquidityRoot
    ) {
        // Compute deltaA from priceMaxAB
        uint256 sqrtPriceMaxAB = Math.sqrt(priceMaxAB * ONE / priceAB) * SQRT_ONE;
        deltaA = (priceAB == priceMaxAB) ? 0 : (balanceA * ONE / (sqrtPriceMaxAB - ONE));

        // Compute deltaB from priceMinAB
        uint256 sqrtPriceMinAB = Math.sqrt(priceAB * ONE / priceMinAB) * SQRT_ONE;
        deltaB = (priceAB == priceMinAB) ? 0 : (balanceB * ONE / (sqrtPriceMinAB - ONE));

        // Compute deltaC from priceMaxAC
        uint256 sqrtPriceMaxAC = Math.sqrt(priceMaxAC * ONE / priceAC) * SQRT_ONE;
        deltaC = (priceAC == priceMaxAC) ? 0 : (balanceC * ONE / (sqrtPriceMaxAC - ONE));

        // Calculate initial concentrated balances
        concentratedA = balanceA + deltaA;
        concentratedB = balanceB + deltaB;
        concentratedC = balanceC + deltaC;

        // Compute all price bounds from the deltas
        // All 3D deltas use the base-token formula (√(Pmax/P)), so we swap argument order:
        // the delta that determines the upper bound goes first (→ priceMax slot),
        // the delta that determines the lower bound goes second (→ priceMin slot).
        (priceMinAC,) = computePriceBounds(balanceC, balanceA, deltaC, deltaA, priceAC);
        (priceMinBC, priceMaxBC) = computePriceBounds(balanceC, balanceB, deltaC, deltaB, priceBC);
        liquidityRoot = CubeRoot.cbrt(concentratedA * concentratedB * concentratedC);
    }

    function buildXD(address[] memory tokens, uint256[] memory deltas, uint256[] memory initialConcentrated, uint256 liquidityRoot) internal pure returns (bytes memory) {
        require(tokens.length == deltas.length, ConcentrateArraysLengthMismatch(tokens.length, deltas.length));
        require(tokens.length == initialConcentrated.length, ConcentrateArraysLengthMismatch(tokens.length, initialConcentrated.length));

        bytes memory packed = abi.encodePacked((tokens.length).toUint16());

        // Tokens (20 bytes each)
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, bytes20(tokens[i]));
        }

        // Deltas (uint128)
        for (uint256 i = 0; i < deltas.length; i++) {
            packed = abi.encodePacked(packed, deltas[i].toUint128());
        }

        // Initial concentrated balances (uint128)
        for (uint256 i = 0; i < initialConcentrated.length; i++) {
            packed = abi.encodePacked(packed, initialConcentrated[i].toUint128());
        }

        return abi.encodePacked(packed, liquidityRoot);
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB, uint256 liquidity) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, liquidity);
    }

    function parseXD(bytes calldata args) internal pure returns (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, bytes calldata initialConcentrated, uint256 liquidityRoot) {
        unchecked {
            tokensCount = uint16(bytes2(args.slice(0, 2, ConcentrateParsingMissingTokensCount.selector)));
            uint256 deltasOffset = 2 + 20 * tokensCount;
            uint256 concentratedOffset = deltasOffset + 16 * tokensCount;  // uint128 deltas
            uint256 liquidityRootOffset = concentratedOffset + 16 * tokensCount;  // uint128 concentrated

            tokens = args.slice(2, deltasOffset, ConcentrateParsingMissingTokenAddresses.selector);
            deltas = args.slice(deltasOffset, concentratedOffset, ConcentrateParsingMissingDeltas.selector);
            initialConcentrated = args.slice(concentratedOffset, liquidityRootOffset, ConcentrateParsingMissingInitialBalances.selector);
            liquidityRoot = uint256(bytes32(args.slice(liquidityRootOffset, liquidityRootOffset+32, ConcentrateParsingMissingLiquidityRoots.selector)));
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
    mapping(bytes32 => mapping(address => uint256)) public concentratedBalances;

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
    /// @param args.deltas[]    | 16 bytes * args.tokensCount (uint128)
    /// @param args.initialConcentrated[] | 16 bytes * args.tokensCount (uint128)
    /// @param args.liquidityRoot | 32 bytes
    function _xycConcentrateGrowLiquidity3D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 currentLiquidityPower, uint256 initialLiquidityRoot, uint256 deltaIn, uint256 deltaOut) = _parseXD(ctx, args);

        // Calculate currentLiquidityRoot for 3D (cube root)
        uint256 currentLiquidityRoot = CubeRoot.cbrt(currentLiquidityPower);

        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaIn, initialLiquidityRoot, currentLiquidityRoot);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOut, initialLiquidityRoot, currentLiquidityRoot);

        ctx.runLoop();
        _updateConcentratedBalancesXD(ctx);
    }

    /// @param args.tokensCount | 2 bytes
    /// @param args.tokens[]    | 20 bytes * args.tokensCount
    /// @param args.deltas[]    | 16 bytes * args.tokensCount (uint128)
    /// @param args.initialConcentrated[] | 16 bytes * args.tokensCount (uint128)
    /// @param args.liquidityRoot | 32 bytes
    function _xycConcentrateGrowLiquidity4D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 currentLiquidityPower, uint256 initialLiquidityRoot, uint256 deltaIn, uint256 deltaOut) = _parseXD(ctx, args);

        // Calculate currentLiquidityRoot for 4D (4th root)
        uint256 currentLiquidityRoot = Math.sqrt(Math.sqrt(currentLiquidityPower));

        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaIn, initialLiquidityRoot, currentLiquidityRoot);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOut, initialLiquidityRoot, currentLiquidityRoot);

        ctx.runLoop();
        _updateConcentratedBalancesXD(ctx);
    }

    function _parseXD(Context memory ctx, bytes calldata args) internal view returns (uint256 currentLiquidityPower, uint256 initialLiquidityRoot, uint256 deltaIn, uint256 deltaOut) {
        (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, bytes calldata initialConcentrated, uint256 initialLiquidityRootCd) = XYCConcentrateArgsBuilder.parseXD(args);

        initialLiquidityRoot = initialLiquidityRootCd;
        currentLiquidityPower = 1;

        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 balance = concentratedBalances[ctx.query.orderHash][token];
            if (balance == 0) {
                // Not initialized - take from calldata
                balance = uint128(bytes16(initialConcentrated.slice(i * 16)));
            }

            currentLiquidityPower *= balance;

            uint256 delta = uint128(bytes16(deltas.slice(i * 16)));
            if (ctx.query.tokenIn == token) {
                deltaIn = delta;
            } else if (ctx.query.tokenOut == token) {
                deltaOut = delta;
            }
        }
    }

    function _updateLiquidity2D(Context memory ctx) internal {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            liquidity[ctx.query.orderHash] = (ctx.swap.balanceIn + ctx.swap.amountIn) * (ctx.swap.balanceOut - ctx.swap.amountOut);
        }
    }

    function _updateConcentratedBalancesXD(Context memory ctx) internal {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            concentratedBalances[ctx.query.orderHash][ctx.query.tokenIn] = ctx.swap.balanceIn + ctx.swap.amountIn;
            concentratedBalances[ctx.query.orderHash][ctx.query.tokenOut] = ctx.swap.balanceOut - ctx.swap.amountOut;
        }
    }
}
