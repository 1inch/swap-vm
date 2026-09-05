// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice FeeFlatIn opcode, token in liquidity provider flat percent fee
/// @dev Encoding: [uint24 feeBps]
library FeeFlatIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using ContextLib for Context;
    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);

    Opcode constant opcode = Opcode.FeeFlatIn;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 3;
    }

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(feeBps)), feeBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24 feeBps) internal pure returns (MemoryPtr ptr) {
        require(feeBps < BPS, FeeBpsOutOfRange(feeBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(feeBps, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint24 feeBps) {
        feeBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint24 feeBps = parse(args);

        if (ctx.query.isExactIn) {
            uint256 fee = (ctx.swap.amountIn * feeBps).ceilDiv(BPS);
            ctx.swap.amountIn -= fee;

            uint256 reduction = ctx.swap.amountIn;
            ctx.runLoop();
            reduction -= ctx.swap.amountIn;

            if (reduction == 0) ctx.swap.amountIn += fee;
            else ctx.swap.amountIn += (ctx.swap.amountIn * feeBps).ceilDiv(BPS - feeBps);
        } else {
            ctx.runLoop();
            ctx.swap.amountIn += (ctx.swap.amountIn * feeBps).ceilDiv(BPS - feeBps);
        }
    }
}

/// @notice FeeFlatOut opcode, token out liquidity provider flat percent fee
/// @dev Encoding: [uint24 feeBps]
/// @dev In combination with AMM auto-reinvesting curves may cause superadditive behavior
///   Fees are deposited against swap direction causing a price rollback effect `swap(a) + swap(b) > swap(c)`
library FeeFlatOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using ContextLib for Context;
    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);

    Opcode constant opcode = Opcode.FeeFlatOut;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 3;
    }

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(feeBps)), feeBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24 feeBps) internal pure returns (MemoryPtr ptr) {
        require(feeBps < BPS, FeeBpsOutOfRange(feeBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(feeBps, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint24 feeBps) {
        feeBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint24 feeBps = parse(args);

        if (!ctx.query.isExactIn) ctx.swap.amountOut += (ctx.swap.amountOut * feeBps).ceilDiv(BPS - feeBps);
        ctx.runLoop();
        ctx.swap.amountOut -= (ctx.swap.amountOut * feeBps).ceilDiv(BPS);
    }
}
