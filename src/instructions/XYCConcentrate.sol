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
    error ConcentrateParsingMissingBalances();
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

    /// @notice Compute concentration ratio for multi-token pool using chain calculation
    /// @dev Computes deltas for base pair and returns concentration ratio that can be applied to any number of additional tokens.
    ///      The concentration ratio is derived from token1's concentrated balance.
    /// @param balance0 Balance of token 0 (base pair)
    /// @param balance1 Balance of token 1 (base pair)
    /// @param basePairPrice Current price for base pair (token1/token0 with 1e18 precision)
    /// @param basePairPriceMin Minimum price for base pair concentration range
    /// @param basePairPriceMax Maximum price for base pair concentration range
    /// @return delta0 Delta for token 0
    /// @return delta1 Delta for token 1
    /// @return concentrationRatio Ratio to apply to any additional token: delta_i = balance_i * (concentrationRatio - 1e18) / 1e18
    function computeDeltasChain(
        uint256 balance0,
        uint256 balance1,
        uint256 basePairPrice,
        uint256 basePairPriceMin,
        uint256 basePairPriceMax
    ) public pure returns (
        uint256 delta0,
        uint256 delta1,
        uint256 concentrationRatio
    ) {
        // Step 1: Compute deltas for base pair (tokens 0 and 1)
        (delta0, delta1,) = computeDeltas(
            balance0,
            balance1,
            basePairPrice,
            basePairPriceMin,
            basePairPriceMax
        );

        // Step 2: Compute concentration ratio from token1's concentrated balance
        // concentrationRatio = (balance1 + delta1) / balance1
        // This ratio can be applied to any number of additional tokens
        concentrationRatio = ((balance1 + delta1) * ONE) / balance1;

        return (delta0, delta1, concentrationRatio);
    }

    function buildXD(address[] memory tokens, uint256[] memory deltas, uint256[] memory balances) internal pure returns (bytes memory) {
        require(tokens.length == deltas.length && tokens.length == balances.length, ConcentrateArraysLengthMismatch(tokens.length, deltas.length, balances.length));
        bytes memory packed = abi.encodePacked((tokens.length).toUint16());
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, tokens[i]);
        }
        return abi.encodePacked(packed, deltas, balances);
    }

    function build2D(address tokenA, address tokenB, uint256 deltaA, uint256 deltaB, uint256 liquidity) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = tokenA < tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, liquidity);
    }

    function parseXD(bytes calldata args) internal pure returns (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, bytes calldata balances) {
        unchecked {
            tokensCount = uint16(bytes2(args.slice(0, 2, ConcentrateParsingMissingTokensCount.selector)));
            uint256 deltasOffset = 2 + 20 * tokensCount;
            uint256 subargsOffset = deltasOffset + 32 * tokensCount;
            uint256 balancesOffset = subargsOffset + 32 * tokensCount;

            tokens = args.slice(2, deltasOffset, ConcentrateParsingMissingTokenAddresses.selector);
            deltas = args.slice(deltasOffset, subargsOffset, ConcentrateParsingMissingDeltas.selector);
            balances = args.slice(subargsOffset, balancesOffset, ConcentrateParsingMissingBalances.selector);
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

    mapping(bytes32 => mapping(address => uint256)) public concentratedBalances;

    function _getLiquidity(bytes32 orderHash, address tokenIn, address tokenOut) internal view returns (uint256) {
        return Math.sqrt(concentratedBalances[orderHash][tokenIn] * concentratedBalances[orderHash][tokenOut]);
    }

    function concentratedBalance(uint256 balance, uint256 delta, uint256 initialLiquidity, uint256 currentLiquidity) public pure returns (uint256) {
        return currentLiquidity == 0 ? balance + delta : balance + delta * currentLiquidity / initialLiquidity;
    }

    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]  | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _xycConcentrateGrowLiquidityXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        uint256 currentLiquidity = _getLiquidity(ctx.query.orderHash, ctx.query.tokenIn, ctx.query.tokenOut);
        uint256 initialLiquidity = 1;
        uint256 deltaIn;
        uint256 deltaOut;

        (uint256 tokensCount, bytes calldata tokens, bytes calldata deltas, bytes calldata balances) = XYCConcentrateArgsBuilder.parseXD(args);
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));

            if (ctx.query.tokenIn == token) {
                initialLiquidity *= uint256(bytes32(balances.slice(i * 32)));
                deltaIn = uint256(bytes32(deltas.slice(i * 32)));
            } else if (ctx.query.tokenOut == token) {
                initialLiquidity *= uint256(bytes32(balances.slice(i * 32)));
                deltaOut = uint256(bytes32(deltas.slice(i * 32)));
            }
        }

        initialLiquidity = Math.sqrt(initialLiquidity);

        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaIn, initialLiquidity, currentLiquidity);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOut, initialLiquidity, currentLiquidity);

        ctx.runLoop();
        _updateScales(ctx);
    }

    /// @param args.deltaLt | 32 bytes
    /// @param args.deltaGt | 32 bytes
    function _xycConcentrateGrowLiquidity2D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, ConcentrateShouldBeUsedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        uint256 currentLiquidity = _getLiquidity(ctx.query.orderHash, ctx.query.tokenIn, ctx.query.tokenOut);

        (uint256 deltaIn, uint256 deltaOut, uint256 initialLiquidity) = XYCConcentrateArgsBuilder.parse2D(args, ctx.query.tokenIn, ctx.query.tokenOut);
        ctx.swap.balanceIn = concentratedBalance(ctx.swap.balanceIn, deltaIn, initialLiquidity, currentLiquidity);
        ctx.swap.balanceOut = concentratedBalance(ctx.swap.balanceOut, deltaOut, initialLiquidity, currentLiquidity);

        ctx.runLoop();
        _updateScales(ctx);
    }

    function _updateScales(Context memory ctx) private {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ConcentrateExpectedSwapAmountComputationAfterRunLoop(ctx.swap.amountIn, ctx.swap.amountOut));

        if (!ctx.vm.isStaticContext) {
            concentratedBalances[ctx.query.orderHash][ctx.query.tokenIn] = ctx.swap.balanceIn + ctx.swap.amountIn;
            concentratedBalances[ctx.query.orderHash][ctx.query.tokenOut] = ctx.swap.balanceOut - ctx.swap.amountOut;
        }
    }
}
