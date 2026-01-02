// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library MinRateArgsBuilder {
    using Calldata for bytes;

    error MinRateMissingRateAmountLtArg();
    error MinRateMissingRateAmountGtArg();

    function build(address tokenA, address tokenB, uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        (uint64 rateLt, uint64 rateGt) = tokenA < tokenB ? (rateA, rateB) : (rateB, rateA);
        return abi.encodePacked(rateLt, rateGt);
    }

    function parse(bytes calldata args, address tokenIn, address tokenOut) internal pure returns (uint64 rateIn, uint64 rateOut) {
        uint64 rateLt = uint64(bytes8(args.slice(0, 8, MinRateMissingRateAmountLtArg.selector)));
        uint64 rateGt = uint64(bytes8(args.slice(8, 16, MinRateMissingRateAmountGtArg.selector)));
        (rateIn, rateOut) = tokenIn < tokenOut ? (rateLt, rateGt) : (rateGt, rateLt);
    }
}

contract MinRate {
    using Math for uint256;
    using ContextLib for Context;

    error MinRateFailed(uint256 swapAmountIn, uint256 swapAmountOut, uint256 rateIn, uint256 ratedAmountOut);
    error MinRateExpectedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);
    error MinRateRunLoopExpectToComputeSwapAmounts(uint256 amountIn, uint256 amountOut);

    /// @param args.rateLt | 8 bytes (uint64)
    /// @param args.rateGt | 8 bytes (uint64)
    function _requireMinRate1D(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, MinRateExpectedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));
        (uint256 rateIn, uint256 rateOut) = MinRateArgsBuilder.parse(args, ctx.query.tokenIn, ctx.query.tokenOut);

        (uint256 swapAmountIn, uint256 swapAmountOut) = ctx.runLoop();

        // Checking that: actual_rate >= required_rate
        // But, instead of: swapAmountIn / swapAmountOut >= rateIn / rateOut use cross-multiplication:
        require(
            swapAmountIn * rateOut >= rateIn * swapAmountOut,
            MinRateFailed(swapAmountIn, swapAmountOut, rateIn, rateOut)
        );
    }

    /// @param args.rateLt | 8 bytes (uint64)
    /// @param args.rateGt | 8 bytes (uint64)
    function _adjustMinRate1D(Context memory ctx, bytes calldata args) internal {
        (uint256 rateIn, uint256 rateOut) = MinRateArgsBuilder.parse(args, ctx.query.tokenIn, ctx.query.tokenOut);

        uint256 amountIn = ctx.swap.amountIn;
        uint256 amountOut = ctx.swap.amountOut;

        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, MinRateExpectedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));
        (uint256 swapAmountIn, uint256 swapAmountOut) = ctx.runLoop();
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, MinRateRunLoopExpectToComputeSwapAmounts(ctx.swap.amountIn, ctx.swap.amountOut));

        // Checking that: actual_rate < required_rate
        // But, instead of: swapAmountIn / swapAmountOut < rateIn / rateOut use cross-multiplication:
        if (swapAmountIn * rateOut < rateIn * swapAmountOut) {
            if (ctx.query.isExactIn) {
                ctx.swap.amountOut = amountIn * rateOut / rateIn;
            } else {
                ctx.swap.amountIn = (amountOut * rateIn).ceilDiv(rateOut);
            }
        }
    }
}
