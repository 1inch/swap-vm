// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { Encode } from "../libs/Encode.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionHeader } from "../libs/InstructionHeader.sol";

/// @notice LimitSwap opcode, linear swap in specified direction
/// @dev Encoding: [bool direction]
library LimitSwap {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    using Math for uint256;

    error LimitSwapDirectionMismatch();

    Opcode constant opcode = Opcode.LimitSwap;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 1;
    }

    function build(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        bool direction = tokenIn < tokenOut;
        return build(MemoryPtrLib.alloc(sizeOf()), direction).resolve();
    }

    function build(bool direction) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), direction).resolve();
    }

    function build(MemoryPtr ptrStart, bool direction) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(Encode.bit(direction, 0));
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool direction) {
        direction = args.at(0).asBool(0);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        bool direction = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        require(direction == swapDirection, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            // Partial fill support
            if (ctx.swap.amountIn >= ctx.swap.balanceIn) {
                ctx.swap.amountIn = ctx.swap.balanceIn;
                ctx.swap.amountOut = ctx.swap.balanceOut;
            } else {
                // Floor division for tokenOut favors maker
                ctx.swap.amountOut = ctx.swap.amountIn * ctx.swap.balanceOut / ctx.swap.balanceIn;
            }
        } else {
            // Partial fill support
            if (ctx.swap.amountOut >= ctx.swap.balanceOut) {
                ctx.swap.amountIn = ctx.swap.balanceIn;
                ctx.swap.amountOut = ctx.swap.balanceOut;
            } else {
                // Ceil division for tokenIn favors maker
                ctx.swap.amountIn = (ctx.swap.amountOut * ctx.swap.balanceIn).ceilDiv(ctx.swap.balanceOut);
            }
        }
    }
}

/// @notice LimitSwapFullAmount opcode, swap balanceIn for balanceOut in specified direction
/// @dev Encoding: [bool direction]
library LimitSwapFullAmount {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    error LimitSwapDirectionMismatch();
    error LimitSwapAmountShouldCoverBalance(uint256 amount, uint256 balance);

    Opcode constant opcode = Opcode.LimitSwapFullAmount;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 1;
    }

    function build(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        bool direction = tokenIn < tokenOut;
        return build(MemoryPtrLib.alloc(sizeOf()), direction).resolve();
    }

    function build(bool direction) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), direction).resolve();
    }

    function build(MemoryPtr ptrStart, bool direction) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(Encode.bit(direction, 0));
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool direction) {
        direction = args.at(0).asBool(0);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        bool direction = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        require(direction == swapDirection, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountIn >= ctx.swap.balanceIn, LimitSwapAmountShouldCoverBalance(ctx.swap.amountIn, ctx.swap.balanceIn));
        } else {
            require(ctx.swap.amountOut >= ctx.swap.balanceOut, LimitSwapAmountShouldCoverBalance(ctx.swap.amountOut, ctx.swap.balanceOut));
        }

        ctx.swap.amountIn = ctx.swap.balanceIn;
        ctx.swap.amountOut = ctx.swap.balanceOut;
    }
}
