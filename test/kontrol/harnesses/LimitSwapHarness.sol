// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context } from "../../../src/libs/VM.sol";
import { LimitSwap } from "../../../src/instructions/LimitSwap.sol";

/// @notice External surface over LimitSwap's internal instructions, for symbolic execution.
/// @dev See XYCSwapHarness for why `Context` is assembled in memory rather than passed in.
///
///      LimitSwap additionally compares `ctx.query.tokenIn < ctx.query.tokenOut` against the
///      `makerDirectionLt` byte in `args`, so the token addresses are exposed as parameters.
///      Specs that want to isolate the pricing arithmetic should pass a matching pair; specs
///      targeting the direction guard should deliberately mismatch them.
contract LimitSwapHarness is LimitSwap {
    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 amountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _limitSwap1D(ctx, args);

        amountOut = ctx.swap.amountOut;
    }

    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 amountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _limitSwap1D(ctx, args);

        amountIn = ctx.swap.amountIn;
    }

    /// @notice All-or-nothing variant: `amountIn` must equal `balanceIn` (exact-in) or
    ///         `amountOut` must equal `balanceOut` (exact-out).
    function exactInOnlyFull(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 amountOut) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _limitSwapOnlyFull1D(ctx, args);

        amountOut = ctx.swap.amountOut;
    }
}
