// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionHeader } from "../libs/InstructionHeader.sol";
import { Time } from "../libs/Time.sol";

/// @notice Salt opcode, produce different hashes for duplicated strategies
/// @dev Encoding: [uint64 salt] or [bytes salt]
library Salt {
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.Salt;

    function sizeOf(uint256 saltLength) internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + saltLength;
    }

    function build(uint64 salt) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(8)), salt).resolve();
    }

    function build(MemoryPtr ptrStart, uint64 salt) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(salt, 8);
        ptrStart.patchLength(ptr);
    }

    function build(bytes memory salt) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(salt.length)), salt).resolve();
    }

    function build(MemoryPtr ptrStart, bytes memory salt) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.pushMem(salt);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata) internal pure {
        // Arbitrary args consumed, no length check needed
    }
}

/// @notice Revert opcode, fail with hardcoded exception if reached
/// @dev Encoding: [bytes4 exception] or [bytes exception]
library Revert {
    using InstructionHeader for MemoryPtr;

    error InstructionRevert(bytes exception);

    Opcode constant opcode = Opcode.Revert;

    function sizeOf(uint256 exceptionLength) internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + exceptionLength;
    }

    function build(bytes4 exception) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(4)), exception).resolve();
    }

    function build(MemoryPtr ptrStart, bytes4 exception) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(exception, 4);
        ptrStart.patchLength(ptr);
    }

    function build(bytes memory exception) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(exception.length)), exception).resolve();
    }

    function build(MemoryPtr ptrStart, bytes memory exception) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.pushMem(exception);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata args) internal pure {
        // Arbitrary args consumed, no length check needed

        revert InstructionRevert(args);
    }
}

/// @notice Stop opcode, successfully ends program execution
/// @dev Encoding: []
library Stop {
    using InstructionHeader for MemoryPtr;

    Opcode constant opcode = Opcode.Stop;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        InstructionHeader.exactLength(sizeOf(), args);

        // Nothing to do out of program bytecode
        ctx.setNextPC(type(uint256).max);
    }
}

/// @notice Deadline opcode, fail if deadline is in past
/// @dev Encoding: [uint40 deadline]
library Deadline {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    error DeadlineReached(uint256 deadline);

    Opcode constant opcode = Opcode.Deadline;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 5;
    }

    function build(uint40 deadline) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), deadline).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 deadline) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(deadline, 5);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint40 deadline) {
        deadline = args.at(0).asU40();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        InstructionHeader.exactLength(sizeOf(), args);

        uint40 deadline = Time.resolve(ctx, parse(args));
        require(block.timestamp <= deadline, DeadlineReached(deadline));
    }
}
