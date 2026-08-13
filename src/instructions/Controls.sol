// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Salt opcode, produce different hashes for duplicated strategies
/// @dev Encoding: [uint64 salt] or [bytes salt]
library Salt {
    Opcode constant opcode = Opcode.Salt;

    function build(uint64 salt) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(salt);
        return InstructionBuilder.build(opcode, args);
    }

    function build(bytes memory salt) internal pure returns (bytes memory) {
        bytes memory args = salt;
        return InstructionBuilder.build(opcode, args);
    }

    function exec(Context memory, bytes calldata) internal pure { }
}

/// @notice Revert opcode, fail with hardcoded exception if reached
/// @dev Encoding: [bytes4 exception] or [bytes exception]
library Revert {
    error InstructionRevert(bytes exception);

    Opcode constant opcode = Opcode.Revert;

    function build(bytes4 exception) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(exception);
        return InstructionBuilder.build(opcode, args);
    }

    function build(bytes memory exception) internal pure returns (bytes memory) {
        bytes memory args = exception;
        return InstructionBuilder.build(opcode, args);
    }

    function exec(Context memory, bytes calldata args) internal pure {
        revert InstructionRevert(args);
    }
}

/// @notice Stop opcode, successfully ends program execution
/// @dev Encoding: []
library Stop {
    using ContextLib for Context;

    Opcode constant opcode = Opcode.Stop;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
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

    error DeadlineReached(uint256 deadline);

    Opcode constant opcode = Opcode.Deadline;

    function build(uint40 deadline) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(deadline);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint40 deadline) {
        deadline = args.at(0).asU40();
    }

    function exec(Context memory, bytes calldata args) internal view {
        uint40 deadline = parse(args);
        require(block.timestamp <= deadline, DeadlineReached(deadline));
    }
}
