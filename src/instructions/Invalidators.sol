// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library InvalidatorsArgsBuilder {
    using SafeCast for uint256;
    using Calldata for bytes;

    error InvalidatorsMissingBitIndexArg();

    function buildInvalidateBit(uint32 bitIndex) internal pure returns (bytes memory) {
        return abi.encodePacked(bitIndex);
    }

    function parseBitIndex(bytes calldata args) internal pure returns (uint256 bitIndex) {
        bitIndex = uint32(bytes4(args.slice(0, 4, InvalidatorsMissingBitIndexArg.selector)));
    }
}

/// @title Invalidators - Order invalidation mechanisms for SwapVM
/// @notice Provides mechanisms to track and prevent order replay or overfilling
/// @dev Supports three invalidation strategies: bit-based, token-in based, and token-out based
contract Invalidators {
    using ContextLib for Context;

    error InvalidatorsBitAlreadySet(address maker, uint256 bitIndex, uint256 bitmap);

    error InvalidatorsTokenInExceeded(uint256 prefilled, uint256 amountIn, uint256 balanceIn);
    error InvalidateTokenInExpectsAmountInToBeComputed();

    error InvalidatorTokenOutExceeded(uint256 prefilled, uint256 amountOut, uint256 balanceOut);
    error InvalidateTokenOutExpectsAmountOutToBeComputed();

    mapping(address maker =>
        mapping(uint256 slotIndex => uint256 bitmap)) public bitInvalidators;

    mapping(address maker =>
        mapping(bytes32 orderHash =>
            mapping(address token => uint256 filled))) public tokenInInvalidators;

    mapping(address maker =>
        mapping(bytes32 orderHash =>
            mapping(address token => uint256 filled))) public tokenOutInvalidators;

    function invalidateBit(uint256 bitIndex) external {
        bitInvalidators[msg.sender][bitIndex >> 8] |= (1 << (bitIndex & 0xFF));
    }

    function invalidateTokenIn(bytes32 orderHash, address tokenIn) external {
        tokenInInvalidators[msg.sender][orderHash][tokenIn] = type(uint256).max;
    }

    function invalidateTokenOut(bytes32 orderHash, address tokenOut) external {
        tokenOutInvalidators[msg.sender][orderHash][tokenOut] = type(uint256).max;
    }

    /// @notice Invalidates order using a unique bit index (one-time execution)
    /// @dev Uses a bitmap to efficiently track which orders have been executed
    /// @param args.bitIndex | 4 bytes (uint32)
    function _invalidateBit1D(Context memory ctx, bytes calldata args) internal {
        uint256 bitIndex = InvalidatorsArgsBuilder.parseBitIndex(args);
        uint256 bitmap = bitInvalidators[ctx.query.maker][bitIndex >> 8];
        uint256 bit = (1 << (bitIndex & 0xFF));
        require(bitmap & bit == 0, InvalidatorsBitAlreadySet(ctx.query.maker, bitIndex, bitmap));
        if (!ctx.vm.isStaticContext) {
            bitInvalidators[ctx.query.maker][bitIndex >> 8] |= bit;
        }
    }

    /// @notice Tracks input token consumption for partial fill orders
    /// @dev Prevents overfilling by tracking cumulative amountIn per order
    function _invalidateTokenIn1D(Context memory ctx, bytes calldata /* args */) internal {
        // Wait till amountIn computed in case of !isExactIn
        if (ctx.swap.amountIn == 0) {
            ctx.runLoop();
        }

        require(ctx.swap.amountIn > 0, InvalidateTokenInExpectsAmountInToBeComputed());
        uint256 prefilled = tokenInInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenIn];
        uint256 newFilled = prefilled + ctx.swap.amountIn;
        require(newFilled <= ctx.swap.balanceIn, InvalidatorsTokenInExceeded(prefilled, ctx.swap.amountIn, ctx.swap.balanceIn));
        if (!ctx.vm.isStaticContext) {
            tokenInInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenIn] = newFilled;
        }
    }

    /// @notice Tracks output token distribution for partial fill orders
    /// @dev Prevents overfilling by tracking cumulative amountOut per order
    function _invalidateTokenOut1D(Context memory ctx, bytes calldata /* args */) internal {
        // Wait till amountOut computed in case of isExactIn
        if (ctx.swap.amountOut == 0) {
            ctx.runLoop();
        }

        require(ctx.swap.amountOut > 0, InvalidateTokenOutExpectsAmountOutToBeComputed());
        uint256 prefilled = tokenOutInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut];
        uint256 newFilled = prefilled + ctx.swap.amountOut;
        require(newFilled <= ctx.swap.balanceOut, InvalidatorTokenOutExceeded(prefilled, ctx.swap.amountOut, ctx.swap.balanceOut));
        if (!ctx.vm.isStaticContext) {
            tokenOutInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut] = newFilled;
        }
    }
}
