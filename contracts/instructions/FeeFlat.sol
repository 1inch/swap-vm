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
        FeeRegisters memory feeRegs = ctx.feeRegisters;
        bool isTakerSide = ctx.query.isExactIn;

        if (!isTakerSide) {
            ctx.runLoop();

            uint256 base = ctx.swap.amountIn - feeRegs.computedFeeAmount;
            uint256 fee = (base * feeBps).ceilDiv(BPS);
            feeRegs.computedFeeAmount += fee;
            ctx.swap.amountIn += fee;
        } else if (feeBps == 0) {
            ctx.runLoop();
        } else {
            if (feeRegs.takerFeeBps == 0) feeRegs.takerAmount = ctx.swap.amountIn;
            uint256 cumBps;
            unchecked { cumBps = feeRegs.takerFeeBps + feeBps; }
            feeRegs.takerFeeBps = cumBps;

            uint256 cumFees = (feeRegs.takerAmount * cumBps).ceilDiv(BPS + cumBps);
            uint256 base;
            unchecked { base = feeRegs.takerAmount - cumFees; }
            ctx.swap.amountIn = base;

            ctx.runLoop();

            uint256 amountIn = ctx.swap.amountIn;
            bool isInnermost = feeRegs.takerFeeBps == cumBps;
            if (isInnermost && amountIn != base) feeRegs.takerAmount = amountIn + (amountIn * cumBps).ceilDiv(BPS);

            uint256 feesLeft;
            unchecked { feesLeft = feeRegs.takerAmount - amountIn; }
            ctx.swap.amountIn = amountIn + (feesLeft * feeBps).ceilDiv(cumBps);
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
        FeeRegisters memory feeRegs = ctx.feeRegisters;
        bool isTakerSide = !ctx.query.isExactIn;

        if (!isTakerSide) {
            ctx.runLoop();

            uint256 base = ctx.swap.amountOut + feeRegs.computedFeeAmount;
            uint256 fee = (base * feeBps).ceilDiv(BPS);
            feeRegs.computedFeeAmount += fee;
            ctx.swap.amountOut -= fee;
        } else if (feeBps == 0) {
            ctx.runLoop();
        } else {
            if (feeRegs.takerFeeBps == 0) feeRegs.takerAmount = ctx.swap.amountOut;
            uint256 cumBps;
            unchecked { cumBps = feeRegs.takerFeeBps + feeBps; }
            require(cumBps < BPS, FeeTotalBpsOutOfRange(cumBps));
            feeRegs.takerFeeBps = cumBps;

            uint256 cumFees = (feeRegs.takerAmount * cumBps).ceilDiv(BPS - cumBps);
            uint256 base = feeRegs.takerAmount + cumFees;
            ctx.swap.amountOut = base;

            ctx.runLoop();

            uint256 amountOut = ctx.swap.amountOut;
            bool isInnermost = feeRegs.takerFeeBps == cumBps;
            if (isInnermost && amountOut != base) feeRegs.takerAmount = amountOut - (amountOut * cumBps).ceilDiv(BPS);

            uint256 feesLeft;
            unchecked { feesLeft = amountOut - feeRegs.takerAmount; }
            ctx.swap.amountOut = amountOut - (feesLeft * feeBps).ceilDiv(cumBps);
        }
    }
}
