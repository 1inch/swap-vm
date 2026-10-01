// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { Time } from "../libs/Time.sol";

/// @notice PiecewiseLinearSurchargeBalanceIn opcode, apply a piecewise-linear percent surcharge to the balance in (maker exact sell)
///   Applies initial percent surcharge before start and last percent surcharge after end
/// @dev Surcharge formula `balance * scale / 2 ** 24`
/// @dev To build a Dutch auction, start with max surcharge percent and decrease it over time towards zero
///   Order balance in is the "maker receive at least" value
/// @dev Encoding: [uint40 timestamp, uint24 scales[k], uint16 durations[k] ...], `durations.length == scales.length - 1`
/// @dev Should not be used with InvalidateTokenIn because it relies on balance in which is modified here
library PiecewiseLinearSurchargeBalanceIn {
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PiecewiseLinearSurchargeBalanceIn;

    function sizeOf(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + PiecewiseLinearSurcharge.sizeOf(timestamp, durations, scales);
    }

    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(timestamp, durations, scales)), timestamp, durations, scales).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint40 timestamp,
        uint16[] memory durations,
        uint24[] memory scales
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = PiecewiseLinearSurcharge.build(ptr, timestamp, durations, scales);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint256 scale = PiecewiseLinearSurcharge.calcScaleNow(ctx, args);
        uint256 surcharge = (ctx.swap.balanceIn * scale) >> 24;

        ctx.swap.surcharge += surcharge;
        ctx.swap.balanceIn += surcharge;
    }

    /// @notice Scale value external helper
    function scaleValue(uint256 value, uint24 scale) internal pure returns (uint256 scaled) {
        scaled = (value * scale) >> 24;
    }
}

/// @notice PiecewiseLinearSurchargeBalanceOut opcode, apply a piecewise-linear percent surcharge to the balance out (maker exact buy)
///   Applies initial percent surcharge before start and last percent surcharge after end
/// @dev Surcharge formula `balance * scale / (2 ** 24 + scale)`
/// @dev To build a Dutch auction, start with max surcharge percent and decrease it over time towards zero
///   Order balance out is the "maker spend at most" value
/// @dev Encoding: [uint40 timestamp, uint24 scales[k], uint16 durations[k] ...], `durations.length == scales.length - 1`
/// @dev Should not be used with InvalidateTokenOut because it relies on balance out which is modified here
library PiecewiseLinearSurchargeBalanceOut {
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PiecewiseLinearSurchargeBalanceOut;

    function sizeOf(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + PiecewiseLinearSurcharge.sizeOf(timestamp, durations, scales);
    }

    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(timestamp, durations, scales)), timestamp, durations, scales).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint40 timestamp,
        uint16[] memory durations,
        uint24[] memory scales
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = PiecewiseLinearSurcharge.build(ptr, timestamp, durations, scales);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint256 scale = PiecewiseLinearSurcharge.calcScaleNow(ctx, args);
        uint256 surcharge = ctx.swap.balanceOut * scale / ((1 << 24) + scale);

        ctx.swap.surcharge += surcharge;
        ctx.swap.balanceOut -= surcharge;
    }

    /// @notice Scale value external helper
    function scaleValue(uint256 value, uint24 scale) internal pure returns (uint256 scaled) {
        scaled = (value * scale) / ((1 << 24) + scale);
    }
}

library PiecewiseLinearSurcharge {
    using InstructionArgs for bytes;
    using PiecewiseLinearSurcharge for bytes;

    error PiecewiseLinearSurchargeMismatchInputLengths();
    error PiecewiseLinearSurchargeNotEnoughPointsToBuildPiece();

    function sizeOf(uint40, uint16[] memory durations, uint24[] memory scales) internal pure returns (uint256) {
        return 5 + durations.length * 2 + scales.length * 3;
    }

    function build(MemoryPtr ptr, uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (MemoryPtr) {
        require(scales.length >= 2, PiecewiseLinearSurchargeNotEnoughPointsToBuildPiece());
        require(durations.length + 1 == scales.length, PiecewiseLinearSurchargeMismatchInputLengths());

        ptr = ptr.push(timestamp, 5).push(scales[0], 3);
        for (uint256 i; i < durations.length; i++) {
            ptr = ptr.push(durations[i], 2).push(scales[i + 1], 3);
        }

        return ptr;
    }

    function parseStartTimestamp(bytes calldata args) internal pure returns (uint40 ts) {
        ts = args.at(0).asU40();
    }

    function parsePointScale(bytes calldata args, uint256 n) internal pure returns (uint24 scale) {
        // Skip [start, n * [scale[k], duration[k]]]
        unchecked { scale = args.at(5 + 5 * n).asU24(); }
    }

    function parseIntervalDuration(bytes calldata args, uint256 n) internal pure returns (uint16 duration) {
        // Skip [start, scale[0], n * [duration[k], scale[k + 1]]]
        unchecked { duration = args.at((5 + 3) + 5 * n).asU16(); }
    }

    function parseIntervalsCount(bytes calldata args) internal pure returns (uint256 count) {
        // Skip [start, scale[0]], divide by [duration, scale] length
        unchecked { count = (args.length - (5 + 3)) / 5; }
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
