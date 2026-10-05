// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { Encode } from "../libs/Encode.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionHeader } from "../libs/InstructionHeader.sol";

/// @notice Jump opcode, jump to specified program location
/// @dev Encoding: [uint16 nextPC]
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Next PC is limited to 2 bytes
library Jump {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.Jump;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 2;
    }

    function build(uint16 nextPC) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), nextPC).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 nextPC) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(nextPC, 2);
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionHeader.sizeOf()).patch(nextPC, 2);
    }

    function parse(bytes calldata args) internal pure returns (uint16 nextPC) {
        nextPC = args.at(0).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        uint16 nextPC = parse(args);
        ctx.setNextPC(nextPC);
    }
}

/// @notice JumpIfDirection opcode, jump if swap direction matches the expected one
/// @dev Encoding: [bool swapDirection, uint16 nextPC]
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Next PC is limited to 2 bytes
library JumpIfDirection {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.JumpIfDirection;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 1 + 2;
    }

    function build(address tokenIn, address tokenOut, uint16 nextPC) internal pure returns (bytes memory) {
        bool direction = tokenIn < tokenOut;
        return build(MemoryPtrLib.alloc(sizeOf()), direction, nextPC).resolve();
    }

    function build(bool direction, uint16 nextPC) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), direction, nextPC).resolve();
    }

    function build(MemoryPtr ptrStart, bool direction, uint16 nextPC) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(Encode.bit(direction, 0)).push(nextPC, 2);
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionHeader.sizeOf() + 1).patch(nextPC, 2);
    }

    function parse(bytes calldata args) internal pure returns (bool direction, uint16 nextPC) {
        direction = args.at(0).asBool(0);
        nextPC = args.at(1).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        (bool direction, uint16 nextPC) = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        if (direction == swapDirection) {
            ctx.setNextPC(nextPC);
        }
    }
}

/// @notice JumpIfTokenIn opcode, jump if token in matches the expected one
/// @dev Encoding: [address token, uint16 nextPC]
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Next PC is limited to 2 bytes
library JumpIfTokenIn {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.JumpIfTokenIn;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 20 + 2;
    }

    function build(address token, uint16 nextPC) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), token, nextPC).resolve();
    }

    function build(MemoryPtr ptrStart, address token, uint16 nextPC) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(token).push(nextPC, 2);
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionHeader.sizeOf() + 20).patch(nextPC, 2);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint16 nextPC) {
        token = args.at(0).asAddress();
        nextPC = args.at(20).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        (address token, uint16 nextPC) = parse(args);
        if (token == ctx.query.tokenIn) {
            ctx.setNextPC(nextPC);
        }
    }
}

/// @notice JumpIfTokenOut opcode, jump if token out matches the expected one
/// @dev Encoding: [address token, uint16 nextPC]
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Next PC is limited to 2 bytes
library JumpIfTokenOut {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.JumpIfTokenOut;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 20 + 2;
    }

    function build(address token, uint16 nextPC) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), token, nextPC).resolve();
    }

    function build(MemoryPtr ptrStart, address token, uint16 nextPC) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(token).push(nextPC, 2);
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionHeader.sizeOf() + 20).patch(nextPC, 2);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint16 nextPC) {
        token = args.at(0).asAddress();
        nextPC = args.at(20).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        (address token, uint16 nextPC) = parse(args);
        if (token == ctx.query.tokenOut) {
            ctx.setNextPC(nextPC);
        }
    }
}
