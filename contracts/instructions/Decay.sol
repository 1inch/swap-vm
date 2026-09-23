// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Decay opcode, increase balance in and decrease balance out by offsets decaying over time since last trade
///   Offsets are increased at each swap by amount in and amount out against the current swap direction
///   making the immediate counter-swap price the same as if no swap occurred and releasing liquidity over time
/// @dev Encoding: [uint16 period]
/// @dev The opcode is expected to be executed only once in strategy flow, storage vars are written by the first-met opcode instance
library Decay {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    function sizeOf(uint16) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2;
    }

    function build(uint16 period) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(period)), period).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 period) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(period, 2);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    struct Offsets {
        DecayOffset aToB;
        DecayOffset bToA;
    }

    struct Storage {
        mapping(bytes32 orderHash => Offsets) offsets;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        Offsets storage offsets = $.offsets[ctx.query.orderHash];
        bool aToB = ctx.query.tokenIn < ctx.query.tokenOut;

        DecayOffset offsetForward;
        DecayOffset offsetBackward;
        if (aToB) (offsetForward, offsetBackward) = (offsets.aToB, offsets.bToA);
        else (offsetForward, offsetBackward) = (offsets.bToA, offsets.aToB);

        (uint112 offsetInForward, uint112 offsetOutForward) = calcOffsetsNow(offsetForward, period);
        ctx.swap.balanceIn += offsetInForward;
        ctx.swap.balanceOut -= offsetOutForward;

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        (uint112 offsetInBackward, uint112 offsetOutBackward) = calcOffsetsNow(offsetBackward, period);
        offsetInBackward += amountOut.toUint112();
        offsetOutBackward += amountIn.toUint112();

        if (!ctx.vm.isStaticContext) {
            if (aToB) offsets.bToA = DecayOffsetLib.encode(offsetInBackward, offsetOutBackward);
            else offsets.aToB = DecayOffsetLib.encode(offsetInBackward, offsetOutBackward);
        }
    }

    function calcOffsetsNow(DecayOffset data, uint16 period) internal view returns (uint112, uint112) {
        unchecked {
            (uint112 offsetIn, uint112 offsetOut, uint32 ts) = DecayOffsetLib.decode(data);

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return (0, 0);
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return (uint112(offsetIn * timeLeft / period), uint112(offsetOut * timeLeft / period));
        }
    }
}

type DecayOffset is uint256;

library DecayOffsetLib {
    function encode(uint112 offsetIn, uint112 offsetOut) internal view returns (DecayOffset) {
        return DecayOffset.wrap((uint256(offsetIn) << 144) | uint256(offsetOut) << 32 | block.timestamp);
    }

    function decode(DecayOffset data) internal pure returns (uint112 offsetIn, uint112 offsetOut, uint32 ts) {
        uint256 raw = DecayOffset.unwrap(data);
        return (uint112(raw >> 144), uint112(raw >> 32), uint32(raw));
    }
}
