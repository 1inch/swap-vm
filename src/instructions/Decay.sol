// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
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
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    function build(uint16 period) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(period);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    struct Storage {
        mapping(bytes32 orderHash => mapping(address token => mapping(bool direction => DecayOffset))) offset;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        ctx.swap.balanceIn += calcOffsetNow($.offset[ctx.query.orderHash][ctx.query.tokenIn][true], period);
        ctx.swap.balanceOut -= calcOffsetNow($.offset[ctx.query.orderHash][ctx.query.tokenOut][false], period);

        uint216 offsetIn = calcOffsetNow($.offset[ctx.query.orderHash][ctx.query.tokenIn][false], period);
        uint216 offsetOut = calcOffsetNow($.offset[ctx.query.orderHash][ctx.query.tokenOut][true], period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        offsetIn += amountIn.toUint216();
        offsetOut += amountOut.toUint216();

        if (!ctx.vm.isStaticContext) {
            $.offset[ctx.query.orderHash][ctx.query.tokenIn][false] = DecayOffsetLib.encode(offsetIn, uint40(block.timestamp));
            $.offset[ctx.query.orderHash][ctx.query.tokenOut][true] = DecayOffsetLib.encode(offsetOut, uint40(block.timestamp));
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
