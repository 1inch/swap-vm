// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Jump opcode, jump to specified program location
/// @dev Encoding: [uint16 nextPC]
/// @dev Next PC is limited to 2 bytes
library Jump {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.Jump;

    function build(uint16 nextPC) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(nextPC);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint16 nextPC) {
        nextPC = args.at(0).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint16 nextPC = parse(args);
        ctx.setNextPC(nextPC);
    }
}

/// @notice JumpIfDirection opcode, jump if swap direction matches the expected one
/// @dev Encoding: [bool swapDirection, uint16 nextPC]
/// @dev Next PC is limited to 2 bytes
library JumpIfDirection {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.JumpIfDirection;

    function build(address tokenIn, address tokenOut, uint16 nextPC) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(InstructionBuilder.encodeBool(tokenIn < tokenOut, 0), nextPC);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (bool direction, uint16 nextPC) {
        direction = args.at(0).asBool(0);
        nextPC = args.at(1).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (bool direction, uint16 nextPC) = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        if (direction == swapDirection) {
            ctx.setNextPC(nextPC);
        }
    }
}

/// @notice JumpIfTokenIn opcode, jump if token in matches the expected one
/// @dev Encoding: [address token, uint16 nextPC]
/// @dev Next PC is limited to 2 bytes
library JumpIfTokenIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.JumpIfTokenIn;

    function build(address token, uint16 nextPC) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, nextPC);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint16 nextPC) {
        token = args.at(0).asAddress();
        nextPC = args.at(20).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (address token, uint16 nextPC) = parse(args);
        if (token == ctx.query.tokenIn) {
            ctx.setNextPC(nextPC);
        }
    }
}

/// @notice JumpIfTokenOut opcode, jump if token out matches the expected one
/// @dev Encoding: [address token, uint16 nextPC]
/// @dev Next PC is limited to 2 bytes
library JumpIfTokenOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.JumpIfTokenOut;

    function build(address token, uint16 nextPC) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, nextPC);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint16 nextPC) {
        token = args.at(0).asAddress();
        nextPC = args.at(20).asU16();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (address token, uint16 nextPC) = parse(args);
        if (token == ctx.query.tokenOut) {
            ctx.setNextPC(nextPC);
        }
    }
}
