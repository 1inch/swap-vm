// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice InvalidateBit opcode, restricts order to be executed only once by maker-scoped nonce
/// @dev Encoding: [uint32 bitIndex]
library InvalidateBit {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    error InvalidateBitAlreadySet(address maker, uint256 bitIndex, uint256 bitmap);

    Opcode constant opcode = Opcode.InvalidateBit;

    function build(uint32 bitIndex) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(bitIndex);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint32 bitIndex) {
        bitIndex = args.at(0).asU32();
    }

    struct Storage {
        mapping(address maker => mapping(uint256 slotIndex => uint256)) bitmap;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateBit")) - 1)) & ~bytes32(uint256(0xff));
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint32 bitIndex = parse(args);
        uint256 slot = bitIndex >> 8;

        uint256 bitmap = $.bitmap[ctx.query.maker][slot];
        uint256 bit = 1 << (bitIndex & 0xff);
        require(bitmap & bit == 0, InvalidateBitAlreadySet(ctx.query.maker, bitIndex, bitmap));

        ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            $.bitmap[ctx.query.maker][slot] |= bit;
        }
    }
}

contract InvalidateBitExternal {
    event InvalidateBitUpdated(address indexed maker, uint256 slotIndex, uint256 slotValue);

    function bitInvalidators(address maker, uint256 slotIndex) external view returns (uint256) {
        InvalidateBit.Storage storage $ = InvalidateBit.store();
        return $.bitmap[maker][slotIndex];
    }

    function invalidateBit(uint256 bitIndex) external {
        InvalidateBit.Storage storage $ = InvalidateBit.store();

        uint256 slot = bitIndex >> 8;
        uint256 newSlotValue = $.bitmap[msg.sender][slot] | (1 << (bitIndex & 0xff));
        $.bitmap[msg.sender][slot] = newSlotValue;
        emit InvalidateBitUpdated(msg.sender, slot, newSlotValue);
    }

    function invalidateBits(uint256 slot, uint256 mask) external {
        InvalidateBit.Storage storage $ = InvalidateBit.store();

        uint256 newSlotValue = $.bitmap[msg.sender][slot] | mask;
        $.bitmap[msg.sender][slot] = newSlotValue;
        emit InvalidateBitUpdated(msg.sender, slot, newSlotValue);
    }
}

/// @notice InvalidateTokenIn opcode, bounds cumulative amount in across all fills by the strategy balance in
///   Balance in is cached at the moment of opcode execution while amount in is taken after rest of strategy executed
/// @dev Encoding: []
/// @dev The opcode is expected to be executed only once in strategy flow, storage vars are written by the first-met opcode instance
library InvalidateTokenIn {
    using ContextLib for Context;

    error InvalidateTokenInExceeded(uint256 filled, uint256 amount, uint256 balance);

    Opcode constant opcode = Opcode.InvalidateTokenIn;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
    }

    struct Storage {
        mapping(address maker => mapping(bytes32 orderHash => mapping(address token => uint256))) filled;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateTokenIn")) - 1)) & ~bytes32(uint256(0xff));
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata) internal {
        Storage storage $ = store();

        uint256 balanceIn = ctx.swap.balanceIn;
        uint256 filled = $.filled[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenIn];

        (uint256 amountIn,) = ctx.runLoop();

        filled += amountIn;
        require(filled <= balanceIn, InvalidateTokenInExceeded(filled, amountIn, balanceIn));

        if (!ctx.vm.isStaticContext) {
            $.filled[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenIn] = filled;
        }
    }
}

contract InvalidateTokenInExternal {
    event InvalidateTokenInFilled(address indexed maker, bytes32 indexed orderHash);

    function tokenInInvalidators(address maker, bytes32 orderHash, address token) external view returns (uint256) {
        InvalidateTokenIn.Storage storage $ = InvalidateTokenIn.store();
        return $.filled[maker][orderHash][token];
    }

    function invalidateTokenIn(bytes32 orderHash, address token) external {
        InvalidateTokenIn.Storage storage $ = InvalidateTokenIn.store();

        $.filled[msg.sender][orderHash][token] = type(uint256).max;
        emit InvalidateTokenInFilled(msg.sender, orderHash);
    }
}

/// @notice InvalidateTokenOut opcode, bounds cumulative amount out across all fills by the strategy balance out
///   Balance out is cached at the moment of opcode execution while amount out is taken after rest of strategy executed
/// @dev Encoding: []
/// @dev The opcode is expected to be executed only once in strategy flow, storage vars are written by the first-met opcode instance
library InvalidateTokenOut {
    using ContextLib for Context;

    error InvalidateTokenOutExceeded(uint256 filled, uint256 amount, uint256 balance);

    Opcode constant opcode = Opcode.InvalidateTokenOut;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
    }

    struct Storage {
        mapping(address maker => mapping(bytes32 orderHash => mapping(address token => uint256))) filled;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateTokenOut")) - 1)) & ~bytes32(uint256(0xff));
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata) internal {
        Storage storage $ = store();

        uint256 balanceOut = ctx.swap.balanceOut;
        uint256 filled = $.filled[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut];

        (, uint256 amountOut) = ctx.runLoop();

        filled += amountOut;
        require(filled <= balanceOut, InvalidateTokenOutExceeded(filled, amountOut, balanceOut));

        if (!ctx.vm.isStaticContext) {
            $.filled[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut] = filled;
        }
    }
}

contract InvalidateTokenOutExternal {
    event InvalidateTokenOutFilled(address indexed maker, bytes32 indexed orderHash);

    function tokenOutInvalidators(address maker, bytes32 orderHash, address token) external view returns (uint256) {
        InvalidateTokenOut.Storage storage $ = InvalidateTokenOut.store();
        return $.filled[maker][orderHash][token];
    }

    function invalidateTokenOut(bytes32 orderHash, address token) external {
        InvalidateTokenOut.Storage storage $ = InvalidateTokenOut.store();

        $.filled[msg.sender][orderHash][token] = type(uint256).max;
        emit InvalidateTokenOutFilled(msg.sender, orderHash);
    }
}
