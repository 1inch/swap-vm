// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @notice Salt opcode, produce different hashes for duplicated stategies
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

/// @notice OnlyTakerTokenBalanceNonZero opcode, fail if taker token balance is zero (NFT-compatible)
/// @dev Encoding: [address token]
/// @dev Since EIP-7702, user may delegate it's account to certain code, potentially sharing
///   authorization given even by soulbound NFT with other users
library OnlyTakerTokenBalanceNonZero {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceIsZero(address taker, address token);

    Opcode constant opcode = Opcode.OnlyTakerTokenBalanceNonZero;

    function build(address token) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token) {
        token = args.at(0).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        address token = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
    }
}

/// @notice OnlyTxOriginTokenBalanceNonZero opcode, fail if tx.origin token balance is zero (NFT-compatible)
///   The opcode allows authorized user to fill the order through 3rd-party contracts
/// @dev Encoding: [address token]
/// @dev Validations through tx.origin are considered weak due to possible transaction flow
///   interception: any contract executing tx originated from tx.origin can pass the validation
library OnlyTxOriginTokenBalanceNonZero {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TxOriginTokenBalanceIsZero(address txOrigin, address token);

    Opcode constant opcode = Opcode.OnlyTxOriginTokenBalanceNonZero;

    function build(address token) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token) {
        token = args.at(0).asAddress();
    }

    function exec(Context memory, bytes calldata args) internal view {
        address token = parse(args);
        uint256 balance = IERC20(token).balanceOf(tx.origin);
        require(balance > 0, TxOriginTokenBalanceIsZero(tx.origin, token));
    }
}

/// @notice OnlyTakerTokenBalanceGte opcode, fail if taker token balance is below expected value
/// @dev Encoding: [address token, uint256 amount]
library OnlyTakerTokenBalanceGte {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceIsLessThanRequired(address taker, address token, uint256 balance, uint256 amount);

    Opcode constant opcode = Opcode.OnlyTakerTokenBalanceGte;

    function build(address token, uint256 amount) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, amount);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint256 amount) {
        token = args.at(0).asAddress();
        amount = args.at(20).asU256();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (address token, uint256 amount) = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance >= amount, TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token, balance, amount));
    }
}

/// @notice OnlyTakerTokenSupplyShareGte opcode, fail if taker token share is below expected share
/// @dev Encoding: [address token, uint64 shareE18]
library OnlyTakerTokenSupplyShareGte {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceSupplyShareIsLessThanRequired(
        address taker, address token, uint256 balance, uint256 totalSupply, uint64 shareE18
    );

    Opcode constant opcode = Opcode.OnlyTakerTokenSupplyShareGte;

    function build(address token, uint64 shareE18) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, shareE18);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint64 shareE18) {
        token = args.at(0).asAddress();
        shareE18 = args.at(20).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (address token, uint64 shareE18) = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        uint256 totalSupply = IERC20(token).totalSupply();
        // balance * 1e18 / totalSupply >= minShareE18
        require(
            totalSupply > 0 && balance * 1e18 >= shareE18 * totalSupply,
            TakerTokenBalanceSupplyShareIsLessThanRequired(ctx.query.taker, token, balance, totalSupply, shareE18)
        );
    }
}
