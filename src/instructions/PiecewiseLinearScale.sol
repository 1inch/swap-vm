// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice PiecewiseLinearScaleBalanceIn opcode, apply a piecewise-linear scale to the balance in (maker exact in)
///   Applies initial scale before start and last scale after end
/// @dev Scale formula `value * (scale + 1) / 2 ** 24`
/// @dev To build a Dutch auction, start with 1.0 scale and decrease it over time
///   To correctly build order based on "maker receives at least" value, initial order balance in should be calculated as
///   `PiecewiseLinearScale.unscaleValue(minBalanceIn, lowestScale)`
/// @dev Encoding: [uint40 timestamp, uint24 scales[k], uint16 durations[k] ...], `durations.length == scales.length - 1`
/// @dev Should not be used with `InvalidateTokenIn` because it relies on `ctx.swap.balanceIn` which is modified here
library PiecewiseLinearScaleBalanceIn {
    Opcode constant opcode = Opcode.PiecewiseLinearScaleBalanceIn;

    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        bytes memory args = PiecewiseLinearScale.build(timestamp, durations, scales);
        return InstructionBuilder.build(opcode, args);
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        ctx.swap.balanceIn = (ctx.swap.balanceIn * PiecewiseLinearScale.calcScaleNow(args)) >> 24;
    }
}

/// @notice PiecewiseLinearScaleBalanceOut opcode, apply a piecewise-linear scale to the balance out (maker exact out)
///   Applies initial scale before start and last scale after end
/// @dev Scale formula `value * (scale + 1) / 2 ** 24`
/// @dev To build a Dutch auction, start with a low scale and increase it over time to 1.0
///   To correctly build order based on "maker pays at max" value, set initial order balance to the value,
///   it would be reached at 1.0 scale
/// @dev Encoding: [uint40 timestamp, uint24 scales[k], uint16 durations[k] ...], `durations.length == scales.length - 1`
/// @dev Should not be used with `InvalidateTokenOut` because it relies on `ctx.swap.balanceOut` which is modified here
library PiecewiseLinearScaleBalanceOut {
    Opcode constant opcode = Opcode.PiecewiseLinearScaleBalanceOut;

    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        bytes memory args = PiecewiseLinearScale.build(timestamp, durations, scales);
        return InstructionBuilder.build(opcode, args);
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        ctx.swap.balanceOut = (ctx.swap.balanceOut * PiecewiseLinearScale.calcScaleNow(args)) >> 24;
    }
}

library PiecewiseLinearScale {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using PiecewiseLinearScale for bytes;

    error PiecewiseLinearScaleMismatchInputLengths();
    error PiecewiseLinearScaleNotEnoughPointsToBuildPiece();

    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        require(scales.length >= 2, PiecewiseLinearScaleNotEnoughPointsToBuildPiece());
        require(durations.length + 1 == scales.length, PiecewiseLinearScaleMismatchInputLengths());

        bytes memory code = abi.encodePacked(timestamp, scales[0]);
        for (uint256 i; i < durations.length; i++) {
            code = abi.encodePacked(code, durations[i], scales[i + 1]);
        }

        return code;
    }

    function parseStartTimestamp(bytes calldata args) internal pure returns (uint40 ts) {
        ts = args.at(0).asU40();
    }

    function parsePointScale(bytes calldata args, uint256 n) internal pure returns (uint24 scale) {
        // Skip [start, n * [scale[k], duration[k]]
        unchecked { scale = args.at(5 + 5 * n).asU24(); }
    }

    function parseIntervalDuration(bytes calldata args, uint256 n) internal pure returns (uint16 duration) {
        // Skip [start, scale[0], n * [duration[k], scale[k + 1]]
        unchecked { duration = args.at((5 + 3) + 5 * n).asU16(); }
    }

    function parseIntervalsCount(bytes calldata args) internal pure returns (uint256 count) {
        // Skip [start, scale[0]], divide by [duration, scale] length
        unchecked { count = (args.length - (5 + 3)) / 5; }
    }

    /// @notice Find the current interval and get linear time-weighted scale, returns initial or last scale for no matching interval
    function calcScaleNow(bytes calldata args) internal view returns (uint256 scale) {
        unchecked {
            uint40 start = args.parseStartTimestamp();
            uint256 max = args.parseIntervalsCount(); // max == durations.length == scales.length - 1

            uint256 timeLeft = block.timestamp;

            if (timeLeft <= start) return uint256(args.parsePointScale(0)) + 1; // return initial scale
            timeLeft -= start;

            uint256 num = 0;
            while (args.parseIntervalDuration(num) < timeLeft) {
                timeLeft -= args.parseIntervalDuration(num);

                if (++num == max) return uint256(args.parsePointScale(max)) + 1; // return last scale
            }

            uint256 duration = args.parseIntervalDuration(num); // durations[num] >= timeLeft > 0 -> `duration != 0`, division is safe
            scale = (timeLeft * args.parsePointScale(num + 1) + (duration - timeLeft) * args.parsePointScale(num)) / duration + 1;
        }
    }

    /// @notice Scale value external helper
    function scaleValue(uint256 value, uint24 scale) internal pure returns (uint256 scaled) {
        scaled = (value * (uint256(scale) + 1)) >> 24;
    }

    /// @notice Unscale value back to 1.0 scale rounding up
    /// @dev Calculates order balances from target balance at specific scale (e.g. lowest scale)
    /// @dev Holds `scaleValue(unscaled, scale) == value`
    function unscaleValue(uint256 value, uint24 scale) internal pure returns (uint256 unscaled) {
        unscaled = ((value << 24) + scale) / (uint256(scale) + 1);
    }
}
