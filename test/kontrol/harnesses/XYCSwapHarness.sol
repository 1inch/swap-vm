// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Context } from "../../../src/libs/VM.sol";
import { XYCSwap } from "../../../src/instructions/XYCSwap.sol";

/// @notice External surface over XYCSwap's internal instruction, for symbolic execution.
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. The harness therefore
///      accepts the individual registers and assembles the `Context` in memory.
///
///      `ctx.vm` is left zero-initialised. `_xycSwapXD` reads only `ctx.query.isExactIn`
///      and `ctx.swap`, and never dispatches, so the null function pointer is never
///      invoked. Should a future instruction under test call `ctx.runLoop()`, this
///      harness shape is no longer valid for it.
contract XYCSwapHarness is XYCSwap {
    /// @notice Exact-input direction: the taker fixes `amountIn`, the VM computes `amountOut`.
    function exactIn(uint256 balanceIn, uint256 balanceOut, uint256 amountIn, bytes calldata args)
        external
        pure
        returns (uint256 amountOut)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _xycSwapXD(ctx, args);

        amountOut = ctx.swap.amountOut;
    }

    /// @notice Exact-output direction: the taker fixes `amountOut`, the VM computes `amountIn`.
    function exactOut(uint256 balanceIn, uint256 balanceOut, uint256 amountOut, bytes calldata args)
        external
        pure
        returns (uint256 amountIn)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _xycSwapXD(ctx, args);

        amountIn = ctx.swap.amountIn;
    }

    /// @notice Exact-input entry that leaves `amountOut` pre-populated, to exercise the
    ///         recompute guard rather than the pricing path.
    function exactInWithAmountOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external pure returns (uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _xycSwapXD(ctx, args);

        return ctx.swap.amountOut;
    }
}
