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
///   Offsets are increased at each swap by amount in and amount out against the current swap direction,
///   making immediate counter-swap have a worse price
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

    struct TokenOffsets {
        DecayOffset asTokenIn;
        DecayOffset asTokenOut;
    }

    struct Storage {
        mapping(bytes32 orderHash => mapping(address token => TokenOffsets)) offset;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        TokenOffsets storage offsetsIn = $.offset[ctx.query.orderHash][ctx.query.tokenIn];
        TokenOffsets storage offsetsOut = $.offset[ctx.query.orderHash][ctx.query.tokenOut];

        ctx.swap.balanceIn += calcOffsetNow(offsetsIn.asTokenOut, period);
        ctx.swap.balanceOut -= calcOffsetNow(offsetsOut.asTokenIn, period);

        uint216 offsetIn = calcOffsetNow(offsetsIn.asTokenIn, period);
        uint216 offsetOut = calcOffsetNow(offsetsOut.asTokenOut, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        offsetIn += amountIn.toUint216();
        offsetOut += amountOut.toUint216();

        if (!ctx.vm.isStaticContext) {
            offsetsIn.asTokenIn = DecayOffsetLib.encode(offsetIn, uint40(block.timestamp));
            offsetsOut.asTokenOut = DecayOffsetLib.encode(offsetOut, uint40(block.timestamp));
        }
    }

    function calcOffsetNow(DecayOffset data, uint16 period) internal view returns (uint216) {
        unchecked {
            (uint216 offset, uint40 ts) = DecayOffsetLib.decode(data);

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return 0;
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return uint216(offset * timeLeft / period);
        }
    }
}

type DecayOffset is uint256;

library DecayOffsetLib {
    function encode(uint216 offset, uint40 ts) internal pure returns (DecayOffset) {
        return DecayOffset.wrap((uint256(offset) << 40) | ts);
    }

    function decode(DecayOffset data) internal pure returns (uint216 offset, uint40 ts) {
        return (uint216(DecayOffset.unwrap(data) >> 40), uint40(DecayOffset.unwrap(data)));
    }
}
