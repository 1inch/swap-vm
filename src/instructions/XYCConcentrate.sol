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

    /// @notice Compute virtual offsets (deltas) from exact sqrt-price bounds (no ambiguous rounding)
    /// @dev Primary entry point. Accepts pre-computed sqrt-price bounds so callers control
    ///      the exact discrete values — no on-chain sqrt of prices is needed.
    ///
    ///      Solves the concentrated-liquidity quadratic for the implied √P:
    ///        bx · u² + u · (by/√Phi − bx · √Plo) − by = 0,   u = √P
    ///      using the conjugate form when the linear coefficient is negative.
    ///
    ///      In the interior case, deltas are derived directly from balances:
    ///        δA = bA · √P / (√Phi − √P)        δB = bB · √Plo / (√P − √Plo)
    ///
    ///      Rounding: all operations produce a consistent floor of the true √P.
    ///      In the solver, β is computed with ceiling so that:
    ///        - Standard branch: diff is a lower bound → numerator is lower bound → √P floors
    ///        - Conjugate branch: diff is an upper bound → denominator is upper bound → √P floors
    ///      Each delta is then individually floored via mulDiv for the discrete √P, √Plo, √Phi.
    /// @param balanceA Real balance of the base token (tokenA)
    /// @param balanceB Real balance of the quote token (tokenB)
    /// @param sqrtPlo √(lower price bound), 1e18 precision (must be < sqrtPhi)
    /// @param sqrtPhi √(upper price bound), 1e18 precision
    /// @return deltaA Virtual offset for tokenA (rounded down)
    /// @return deltaB Virtual offset for tokenB (rounded down)
    /// @return liquidity Concentrated liquidity L (rounded down)
    /// @return impliedPrice Spot price implied by balances and bounds (1e18 precision)
    function computeDeltasFromSqrtPrices(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPlo,
        uint256 sqrtPhi
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity, uint256 impliedPrice) {
        require(sqrtPlo < sqrtPhi, ConcentrateInconsistentPrices(0, sqrtPlo, sqrtPhi));

        uint256 sqrtP = _solveSqrtPrice(balanceA, balanceB, sqrtPlo, sqrtPhi);

        impliedPrice = Math.mulDiv(sqrtP, sqrtP, ONE);

        uint256 gapHi = sqrtPhi - sqrtP;
        uint256 gapLo = sqrtP - sqrtPlo;

        if (gapHi > 0 && gapLo > 0) {
            deltaA = Math.mulDiv(balanceA, sqrtP, gapHi);
            deltaB = Math.mulDiv(balanceB, sqrtPlo, gapLo);
            liquidity = Math.mulDiv(balanceB, ONE, gapLo);
        } else if (gapHi == 0) {
            liquidity = Math.mulDiv(balanceB, ONE, sqrtPhi - sqrtPlo);
            deltaA = Math.mulDiv(liquidity, ONE, sqrtPhi);
            deltaB = Math.mulDiv(liquidity, sqrtPlo, ONE);
        } else {
            uint256 sqrtProduct = Math.mulDiv(sqrtPlo, sqrtPhi, ONE);
            liquidity = Math.mulDiv(balanceA, sqrtProduct, sqrtPhi - sqrtPlo);
            deltaA = Math.mulDiv(liquidity, ONE, sqrtPhi);
            deltaB = Math.mulDiv(liquidity, sqrtPlo, ONE);
        }
    }

    /// @notice Convenience wrapper that accepts price bounds and computes sqrt prices internally
    /// @dev For production use, prefer computeDeltasFromSqrtPrices with exact sqrt-price values
    ///      to avoid ambiguous rounding from the floor sqrt.
    /// @param balanceA Real balance of the base token (tokenA)
    /// @param balanceB Real balance of the quote token (tokenB)
    /// @param priceMin Lower price bound (tokenB/tokenA, 1e18 precision)
    /// @param priceMax Upper price bound (tokenB/tokenA, 1e18 precision)
    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity, uint256 impliedPrice) {
        uint256 sqrtPlo = Math.sqrt(priceMin * ONE);
        uint256 sqrtPhi = Math.sqrt(priceMax * ONE);
        return computeDeltasFromSqrtPrices(balanceA, balanceB, sqrtPlo, sqrtPhi);
    }

    /// @dev Solve  bx·u² + u·(by/√Phi − bx·√Plo) − by = 0  for u = √Pspot.
    ///
    ///      Rounding strategy (consistent floor of true √P):
    ///        α = mulDiv(bA, √Plo, ONE)              — floor
    ///        β = mulDiv(bB, ONE, √Phi, Ceil)         — ceil
    ///
    ///      Branch on α ≥ β:
    ///        Standard:  diff = α − β (lower bound), √D = floor(√(diff²+4·bA·bB))
    ///                   → numerator = diff + √D is lower bound → mulDiv floors → √P floors ✓
    ///        Conjugate: diff = β − α (upper bound), √D = ceil(√(diff²+4·bA·bB))
    ///                   → denominator = diff + √D is upper bound → mulDiv floors → √P floors ✓
    ///
    ///      Result is clamped to [sqrtPlo, sqrtPhi].
    function _solveSqrtPrice(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPlo,
        uint256 sqrtPhi
    ) private pure returns (uint256 sqrtP) {
        if (balanceA == 0) return sqrtPhi;
        if (balanceB == 0) return sqrtPlo;

        uint256 alpha = Math.mulDiv(balanceA, sqrtPlo, ONE);
        uint256 betaCeil = Math.mulDiv(balanceB, ONE, sqrtPhi, Math.Rounding.Ceil);

        if (alpha >= betaCeil) {
            // Standard form: sqrtP = ONE · (diff + √D) / (2·bA)
            // diff is lower bound (floor α − ceil β), √D is floor → numerator is lower bound
            uint256 diff = alpha - betaCeil;
            uint256 sqrtDisc = Math.sqrt(diff * diff + 4 * balanceA * balanceB);
            sqrtP = Math.mulDiv(ONE, diff + sqrtDisc, 2 * balanceA);
        } else {
            // Conjugate form: sqrtP = 2·bB·ONE / (diff + √D)
            // diff is upper bound (ceil β − floor α), √D is ceil → denominator is upper bound
            uint256 diff = betaCeil - alpha;
            uint256 sqrtDisc = Math.sqrt(diff * diff + 4 * balanceA * balanceB, Math.Rounding.Ceil);
            sqrtP = Math.mulDiv(balanceB, 2 * ONE, diff + sqrtDisc);
        }

        if (sqrtP < sqrtPlo) sqrtP = sqrtPlo;
        else if (sqrtP > sqrtPhi) sqrtP = sqrtPhi;
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
