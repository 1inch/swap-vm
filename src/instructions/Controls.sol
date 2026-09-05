// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Salt opcode, produce different hashes for duplicated strategies
/// @dev Encoding: [uint64 salt] or [bytes salt]
library Salt {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.Salt;

    function sizeOf(uint64) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 8;
    }

    function build(uint64 salt) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(salt)), salt).resolve();
    }

    function build(MemoryPtr ptrStart, uint64 salt) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(salt, 8);
        ptrStart.patchLength(ptr);
    }

    function sizeOf(bytes memory salt) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + salt.length;
    }

    function build(bytes memory salt) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(salt)), salt).resolve();
    }

    function build(MemoryPtr ptrStart, bytes memory salt) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.pushMem(salt);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata) internal pure { }
}

/// @notice Revert opcode, fail with hardcoded exception if reached
/// @dev Encoding: [bytes4 exception] or [bytes exception]
library Revert {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    error InstructionRevert(bytes exception);

    Opcode constant opcode = Opcode.Revert;

    function sizeOf(bytes4) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 4;
    }

    function build(bytes4 exception) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(exception)), exception).resolve();
    }

    function build(MemoryPtr ptrStart, bytes4 exception) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(exception, 4);
        ptrStart.patchLength(ptr);
    }

    function sizeOf(bytes memory exception) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + exception.length;
    }

    function build(bytes memory exception) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(exception)), exception).resolve();
    }

    function build(MemoryPtr ptrStart, bytes memory exception) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.pushMem(exception);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata args) internal pure {
        revert InstructionRevert(args);
    }
}

/// @notice Stop opcode, successfully ends program execution
/// @dev Encoding: []
library Stop {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.Stop;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        // Nothing to do out of program bytecode
        ctx.setNextPC(type(uint256).max);
    }
}

/// @notice Deadline opcode, fail if deadline is in past
/// @dev Encoding: [uint40 deadline]
library Deadline {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    error DeadlineReached(uint256 deadline);

    Opcode constant opcode = Opcode.Deadline;

    function sizeOf(uint40) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 5;
    }

    function build(uint40 deadline) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(deadline)), deadline).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 deadline) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(deadline, 5);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint40 deadline) {
        deadline = args.at(0).asU40();
    }

    function exec(Context memory, bytes calldata args) internal view {
        uint40 deadline = parse(args);
        require(block.timestamp <= deadline, DeadlineReached(deadline));
    }
}
