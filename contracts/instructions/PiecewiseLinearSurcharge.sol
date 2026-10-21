// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { Time } from "../libs/Time.sol";

/// @notice PiecewiseLinearSurcharge opcode, apply a piecewise-linear percent surcharge to balance in or balance out
///   Applies the initial percent surcharge before start and the last percent surcharge after end
/// @dev To build a Dutch auction, start with the maximum surcharge and decrease it over time towards zero
/// @dev Encoding: [bool adjustIn, uint40 timestamp, uint24 scales[k], uint16 durations[k] ...], `durations.length == scales.length - 1`
/// @dev Should not be used with InvalidateTokenIn for `adjustIn = true` or InvalidateTokenOut for `adjustIn = false`
library PiecewiseLinearSurcharge {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;
    using PiecewiseLinearSurcharge for bytes;

    error PiecewiseLinearSurchargeMismatchInputLengths();
    error PiecewiseLinearSurchargeNotEnoughPointsToBuildPiece();

    Opcode constant opcode = Opcode.PiecewiseLinearSurcharge;

    function sizeOf(uint256 durationsLen, uint256 scalesLen) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + 5 + durationsLen * 2 + scalesLen * 3;
    }

    function build(bool adjustIn, uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(durations.length, scales.length)), adjustIn, timestamp, durations, scales).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool adjustIn,
        uint40 timestamp,
        uint16[] memory durations,
        uint24[] memory scales
    ) internal pure returns (MemoryPtr ptr) {
        require(scales.length >= 2, PiecewiseLinearSurchargeNotEnoughPointsToBuildPiece());
        require(durations.length + 1 == scales.length, PiecewiseLinearSurchargeMismatchInputLengths());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(adjustIn, 0)).push(timestamp, 5).push(scales[0], 3);
        for (uint256 i; i < durations.length; i++) {
            ptr = ptr.push(durations[i], 2).push(scales[i + 1], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool adjustIn) {
        adjustIn = args.at(0).asBool(0);
    }

    function parseStartTimestamp(bytes calldata args) internal pure returns (uint40 ts) {
        // Skip [adjustIn]
        ts = args.at(1).asU40();
    }

    function parsePointScale(bytes calldata args, uint256 n) internal pure returns (uint24 scale) {
        // Skip [adjustIn, start, n * [scale[k], duration[k]]]
        unchecked { scale = args.at(1 + 5 + 5 * n).asU24(); }
    }

    function parseIntervalDuration(bytes calldata args, uint256 n) internal pure returns (uint16 duration) {
        // Skip [adjustIn, start, scale[0], n * [duration[k], scale[k + 1]]]
        unchecked { duration = args.at((1 + 5 + 3) + 5 * n).asU16(); }
    }

    function parseIntervalsCount(bytes calldata args) internal pure returns (uint256 count) {
        // Skip [adjustIn, start, scale[0]], divide by [duration, scale] length
        unchecked { count = (args.length - (1 + 5 + 3)) / 5; }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        bool adjustIn = parse(args);
        uint256 scale = calcScaleNow(ctx, args);

        if (adjustIn) {
            uint256 surcharge = (ctx.swap.balanceIn * scale) >> 24;
            ctx.swap.surcharge += surcharge;
            ctx.swap.balanceIn += surcharge;
        } else {
            uint256 surcharge = ctx.swap.balanceOut * scale / ((1 << 24) + scale);
            ctx.swap.surcharge += surcharge;
            ctx.swap.balanceOut -= surcharge;
        }
    }

    /// @notice Find the current interval and get linear time-weighted scale, returns initial or last scale for no matching interval
    function calcScaleNow(Context memory ctx, bytes calldata args) internal returns (uint256 scale) {
        unchecked {
            uint40 start = Time.resolve(ctx, args.parseStartTimestamp());
            uint256 max = args.parseIntervalsCount(); // max == durations.length == scales.length - 1

            uint256 timeLeft = block.timestamp;

            if (timeLeft <= start) return uint256(args.parsePointScale(0)); // return initial scale
            timeLeft -= start;

            uint256 num = 0;
            while (args.parseIntervalDuration(num) < timeLeft) {
                timeLeft -= args.parseIntervalDuration(num);

                if (++num == max) return uint256(args.parsePointScale(max)); // return last scale
            }

            uint256 duration = args.parseIntervalDuration(num); // durations[num] >= timeLeft > 0 -> `duration != 0`, division is safe
            scale = (timeLeft * args.parsePointScale(num + 1) + (duration - timeLeft) * args.parsePointScale(num)) / duration;
        }
    }
}
