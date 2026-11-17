// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context, FeeRegisters } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice FeeFlatIn opcode, token in liquidity provider flat percent fee
/// @dev Fee is feeBps of the net amount in priced by the rest of the program, added to amount in and kept by the maker
///   Priced from the same base as the other fee wrappers, see FeeRegisters
/// @dev Encoding: [uint24 feeBps]
library FeeFlatIn {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);

    Opcode constant opcode = Opcode.FeeFlatIn;

    uint256 constant BPS = 1e7;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 3;
    }

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), feeBps).resolve();
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
        uint256 feeBps = parse(args);
        FeeRegisters memory regs = ctx.feeRegisters;

        if (!ctx.query.isExactIn) {
            ctx.runLoop();
            uint256 fee = ((ctx.swap.amountIn - regs.fee) * feeBps).ceilDiv(BPS);
            regs.fee += fee;
            ctx.swap.amountIn += fee;
        } else if (feeBps == 0) {
            ctx.runLoop();
        } else {
            if (regs.bps == 0) regs.target = ctx.swap.amountIn;
            uint256 cumBps;
            unchecked { cumBps = regs.bps + feeBps; }
            regs.bps = cumBps;
            uint256 carve = (regs.target * cumBps).ceilDiv(BPS + cumBps);
            uint256 base;
            unchecked { base = regs.target - carve; }
            ctx.swap.amountIn = base;

            ctx.runLoop();

            uint256 amountIn = ctx.swap.amountIn;
            if (regs.bps == cumBps && amountIn != base) regs.target = amountIn + (amountIn * cumBps).ceilDiv(BPS);
            uint256 fees;
            unchecked { fees = regs.target - amountIn; }
            ctx.swap.amountIn = amountIn + (fees * feeBps).ceilDiv(cumBps);
        }
    }
}

/// @notice FeeFlatOut opcode, token out liquidity provider flat percent fee
/// @dev Fee is feeBps of the gross amount out priced by the rest of the program, charged from amount out and kept by the maker
///   Priced from the same base as the other fee wrappers, see FeeRegisters
/// @dev Encoding: [uint24 feeBps]
/// @dev In combination with AMM auto-reinvesting curves may cause superadditive behavior
///   Fees are deposited against swap direction causing a price rollback effect `swap(a) + swap(b) > swap(c)`
library FeeFlatOut {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);
    error FeeTotalBpsOutOfRange(uint256 totalBps);

    Opcode constant opcode = Opcode.FeeFlatOut;

    uint256 constant BPS = 1e7;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 3;
    }

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), feeBps).resolve();
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
        uint256 feeBps = parse(args);
        FeeRegisters memory regs = ctx.feeRegisters;

        if (ctx.query.isExactIn) {
            ctx.runLoop();
            uint256 fee = ((ctx.swap.amountOut + regs.fee) * feeBps).ceilDiv(BPS);
            regs.fee += fee;
            ctx.swap.amountOut -= fee;
        } else if (feeBps == 0) {
            ctx.runLoop();
        } else {
            if (regs.bps == 0) regs.target = ctx.swap.amountOut;
            uint256 cumBps;
            unchecked { cumBps = regs.bps + feeBps; }
            require(cumBps < BPS, FeeTotalBpsOutOfRange(cumBps));
            regs.bps = cumBps;
            uint256 base = regs.target + (regs.target * cumBps).ceilDiv(BPS - cumBps);
            ctx.swap.amountOut = base;

            ctx.runLoop();

            uint256 amountOut = ctx.swap.amountOut;
            if (regs.bps == cumBps && amountOut != base) regs.target = amountOut - (amountOut * cumBps).ceilDiv(BPS);
            uint256 fees;
            unchecked { fees = amountOut - regs.target; }
            ctx.swap.amountOut = amountOut - (fees * feeBps).ceilDiv(cumBps);
        }
    }
}
