// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice XYCConcentrateSwap opcode, constant-product swap curve concentrating liquidity in specified price range
///   Automatically reinvests accumulated maker fees
/// @dev Encoding: [uint256 sqrtPriceMin, uint256 sqrtPriceMax]
library XYCConcentrateSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Math for uint256;

    error ConcentrateInvalidPriceBounds(uint256 sqrtPriceMin, uint256 sqrtPriceMax);
    error ConcentrateSpotOutOfRange(uint256 sqrtPriceMin, uint256 sqrtPriceSpot, uint256 sqrtPriceMax);

    Opcode constant opcode = Opcode.XYCConcentrateSwap;

    uint256 constant ONE = 1e18;

    function build(uint256 sqrtPriceMin, uint256 sqrtPriceMax) internal pure returns (bytes memory) {
        require(0 < sqrtPriceMin && sqrtPriceMin < sqrtPriceMax, ConcentrateInvalidPriceBounds(sqrtPriceMin, sqrtPriceMax));

        bytes memory args = abi.encodePacked(sqrtPriceMin, sqrtPriceMax);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint256 sqrtPriceMin, uint256 sqrtPriceMax) {
        sqrtPriceMin = args.at(0).asU256();
        sqrtPriceMax = args.at(32).asU256();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = parse(args);

        bool direction = ctx.query.tokenIn < ctx.query.tokenOut;
        uint256 liquidity = computeLiquidity(
            direction ? ctx.swap.balanceIn : ctx.swap.balanceOut,
            direction ? ctx.swap.balanceOut : ctx.swap.balanceIn,
            sqrtPriceMin,
            sqrtPriceMax
        );

        uint256 virtualIn = ctx.swap.balanceIn;
        uint256 virtualOut = ctx.swap.balanceOut;

        // Rounding virtual in up favors maker
        if (direction) {
            virtualIn += liquidity.mulDiv(ONE, sqrtPriceMax, Math.Rounding.Ceil);
            virtualOut += liquidity.mulDiv(sqrtPriceMin, ONE);
        } else {
            virtualIn += liquidity.mulDiv(sqrtPriceMin, ONE, Math.Rounding.Ceil);
            virtualOut += liquidity.mulDiv(ONE, sqrtPriceMax);
        }

        if (ctx.query.isExactIn) {
            // Floor division for tokenOut favors maker
            ctx.swap.amountOut = ctx.swap.amountIn * virtualOut / (virtualIn + ctx.swap.amountIn);
        } else {
            // Ceil division for tokenIn favors maker
            ctx.swap.amountIn = (ctx.swap.amountOut * virtualIn).ceilDiv(virtualOut - ctx.swap.amountOut);
        }
    }

    /// @notice Compute liquidity from balances and price bounds
    /// @dev Solves invariant as quadratic equation
    ///   Invariant: `(balanceA + virtualA) * (balanceB + virtualB) = liquidity ** 2`
    ///     where `virtualA = liquidity / sqrtPriceMax` and `virtualB = liquidity * sqrtPriceMin`
    ///
    ///   Equation: `(1 - sqrtPriceMin / sqrtPriceMax) * liquidity ** 2 - beta * liquidity - balanceA * balanceB = 0`
    ///     where `beta = balanceA * sqrtPriceMin + balanceB / sqrtPriceMax`
    ///
    ///   Positive root: `liquidity = (beta + sqrt(beta ** 2 + 4 * (sqrtPriceMax - sqrtPriceMin) * balanceA * balanceB / sqrtPriceMax)) *
    ///     sqrtPriceMax / (2 * (sqrtPriceMax - sqrtPriceMin))`
    function computeLiquidity(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256) {
        uint256 priceDelta = sqrtPriceMax - sqrtPriceMin;
        uint256 beta = balanceA.mulDiv(sqrtPriceMin, ONE) + balanceB.mulDiv(ONE, sqrtPriceMax);
        uint256 fourAC = (4 * priceDelta).mulDiv(balanceA * balanceB, sqrtPriceMax);
        uint256 disc = beta * beta + fourAC;

        return (beta + disc.sqrt()).mulDiv(sqrtPriceMax, 2 * priceDelta);
    }

    /// @notice Price estimation helper
    ///   Actual swap rate may slightly differ due to rounding amounts favor maker
    function computeLiquidityAndPrice(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256 liquidity, uint256 sqrtPriceSpot) {
        liquidity = computeLiquidity(balanceA, balanceB, sqrtPriceMin, sqrtPriceMax);

        uint256 virtualA = balanceA + liquidity.mulDiv(ONE, sqrtPriceMax);
        uint256 virtualB = balanceB + liquidity.mulDiv(sqrtPriceMin, ONE);

        sqrtPriceSpot = virtualB.mulDiv(ONE * ONE, virtualA).sqrt();
    }

    /// @notice Approximate initial balances for given liquidity, boundaries and spot price
    ///   Returns a raw estimation, a slightly better balance pair may exist with liquidity closer to the target
    /// @dev Computations rationale
    ///   `balanceA = virtualA(sqrtPriceSpot) - virtualA(sqrtPriceMax)`
    ///   `balanceB = virtualB(sqrtPriceSpot) - virtualB(sqrtPriceMin)`
    ///     where `virtualA(sqrtPrice) = liquidity / sqrtPrice` and `virtualB(sqrtPrice) = liquidity * sqrtPrice`
    /// @dev Holds `computeLiquidity(balanceA, balanceB, sqrtPriceMin, sqrtPriceMax) <= liquidity`
    function computeBalances(
        uint256 liquidity,
        uint256 sqrtPriceSpot,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256 balanceA, uint256 balanceB) {
        require(sqrtPriceMin < sqrtPriceMax, ConcentrateInvalidPriceBounds(sqrtPriceMin, sqrtPriceMax));
        require(sqrtPriceMin <= sqrtPriceSpot, ConcentrateSpotOutOfRange(sqrtPriceMin, sqrtPriceSpot, sqrtPriceMax));
        require(sqrtPriceSpot <= sqrtPriceMax, ConcentrateSpotOutOfRange(sqrtPriceMin, sqrtPriceSpot, sqrtPriceMax));

        balanceA = liquidity.mulDiv((sqrtPriceMax - sqrtPriceSpot) * ONE, sqrtPriceSpot * sqrtPriceMax);
        balanceB = liquidity.mulDiv(sqrtPriceSpot - sqrtPriceMin, ONE);
    }

    /// @notice Approximate initial balances from available token amounts, boundaries and spot price
    ///   Returns a raw estimation, a slightly better balance pair may exist resulting in bigger liquidity
    /// @dev Holds `actualA <= availableA` and `actualB <= availableB`
    function computeLiquidityFromAmounts(
        uint256 availableA,
        uint256 availableB,
        uint256 sqrtPriceSpot,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax
    ) internal pure returns (uint256 liquidity, uint256 actualA, uint256 actualB) {
        require(sqrtPriceMin < sqrtPriceMax, ConcentrateInvalidPriceBounds(sqrtPriceMin, sqrtPriceMax));
        require(sqrtPriceMin <= sqrtPriceSpot, ConcentrateSpotOutOfRange(sqrtPriceMin, sqrtPriceSpot, sqrtPriceMax));
        require(sqrtPriceSpot <= sqrtPriceMax, ConcentrateSpotOutOfRange(sqrtPriceMin, sqrtPriceSpot, sqrtPriceMax));

        if (sqrtPriceSpot <= sqrtPriceMin) {
            liquidity = availableA.mulDiv(sqrtPriceSpot * sqrtPriceMax, (sqrtPriceMax - sqrtPriceSpot) * ONE);
        } else if (sqrtPriceSpot < sqrtPriceMax) {
            uint256 liquidityFromA = availableA.mulDiv(sqrtPriceSpot * sqrtPriceMax, (sqrtPriceMax - sqrtPriceSpot) * ONE);
            uint256 liquidityFromB = availableB.mulDiv(ONE, sqrtPriceSpot - sqrtPriceMin);
            liquidity = liquidityFromA.min(liquidityFromB);
        } else {
            liquidity = availableB.mulDiv(ONE, sqrtPriceSpot - sqrtPriceMin);
        }

        (actualA, actualB) = computeBalances(liquidity, sqrtPriceSpot, sqrtPriceMin, sqrtPriceMax);
        liquidity = computeLiquidity(actualA, actualB, sqrtPriceMin, sqrtPriceMax);
    }
}
