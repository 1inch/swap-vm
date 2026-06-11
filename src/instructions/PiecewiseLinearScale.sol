// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

library PiecewiseLinearScaleArgsBuilder {
    error PiecewiseLinearScaleMismatchInputLengths();
    error PiecewiseLinearScaleNotEnoughPointsToBuildPiece();

    /// @notice Build instruction arguments for PiecewiseLinearScale
    /// @param timestamp First interval start timestamp
    /// @param durations Interval durations
    /// @param scales Packed scale values at timestamp + sum(durations[0:i])
    /// @return args Packed bytes for inclusion in program bytecode
    function build(uint40 timestamp, uint16[] memory durations, uint24[] memory scales) internal pure returns (bytes memory) {
        require(scales.length >= 2, PiecewiseLinearScaleNotEnoughPointsToBuildPiece());
        require(durations.length == scales.length - 1, PiecewiseLinearScaleMismatchInputLengths());

        bytes memory code = abi.encodePacked(timestamp, scales[0]);
        for (uint256 i; i < durations.length; i++) {
            code = abi.encodePacked(code, durations[i], scales[i + 1]);
        }

        return code;
    }

    /// @notice Parse start timestamp
    function parseStartTimestamp(bytes calldata args) internal pure returns (uint256 ts) {
        assembly ("memory-safe") {
            ts := shr(216, calldataload(args.offset))
        }
    }

    /// @notice Parse specific interval duration
    /// @dev Requires args to be shifted by 8 bytes
    function parseIntervalDuration(bytes calldata args, uint256 n) internal pure returns (uint256 duration) {
        assembly ("memory-safe") {
            duration := shr(240, calldataload(add(args.offset, mul(n, 5))))
        }
    }

    /// @notice Parse specific point scale
    /// @dev Requires args to be shifted by 5 bytes
    function parsePointScale(bytes calldata args, uint256 n) internal pure returns (uint256 scale) {
        assembly ("memory-safe") {
            scale := shr(232, calldataload(add(args.offset, mul(n, 5))))
        }
    }

    /// @notice Apply scale to the value
    /// @dev Matches the scaling in opcodes
    function scaleValue(uint256 value, uint24 scale) internal pure returns (uint256 scaled) {
        scaled = (value * (uint256(scale) + 1)) >> 24;
    }

    /// @notice Unscale value back to 1.0 scale rounding up
    /// @dev Use to calculate order balances from target balance at specific scale (e.g. lowest scale)
    /// @dev Holds `scaleValue(unscaled, scale) == value`
    function unscaleValue(uint256 value, uint24 scale) internal pure returns (uint256 unscaled) {
        unscaled = ((value << 24) + scale) / (uint256(scale) + 1);
    }
}

/**
 * @notice Piecewise Linear Scale instruction for time-based linear price decay/rise
 * @dev Implements a balance scaling for linearly changing scale value
 * - Designed to be used after balances set and before a swap instruction
 * - Applies time-based scaling to the balances
 * - Could be used for complex auctions with periods of price increase and decrease
 * - Set scaling before start to first point scale, set scaling after end to last point scale
 *
 * Example usage:
 * 1. Balances set to 1000e18 : 2000e18
 * 2. `_piecewiseLinearScaleBalanceIn1D` is used with args (now, [100, 1000], [0.5, 0.7, 0.3])
 * 3. At start balances would be treated as 500e18 : 2000e18 then linearly go to 700e18 : 2000e18 and later to 300e18 : 2000e18
 * 4. Swap instruction calculates amounts based on updated balances
 *
 * @dev Integration Notes
 * - Scaling is applied to token balances (reserves), not the amounts, this follows Exact In/Out Symmetry SwapVM Invariant
 * - Scaling basis points are 2 ** 24 (comparing to 10 ** 7 in Fusion), this uses the computation field efficiently, scaling formula: `value * (scale + 1) / 2 ** 24`
 * - Scaling range is (0; 1] (comparing to (~0.373; 1] in Fusion), this contributes to instruction generalization to be not bounded by case-specific limitations
 * - For dutch auction selling specified amount, the order balance would not equal the amount, the amount should be reached as a result of final scaling,
 *   the `unscaleValue(amount, finalScale)` provides the value which would result in desired amount after scaling
 * - The instruction accepts start timestamp, arrays of points and interval durations:
 *   packed [5 bytes timestamp, 3 bytes scales[0], 2 bytes durations[0] ...], `durations.length == scales.length - 1`
 */
contract PiecewiseLinearScale {
    using PiecewiseLinearScaleArgsBuilder for bytes;
    using Calldata for bytes;

    error PiecewiseLinearScaleAmountsAlreadyComputed(uint256 amountIn, uint256 amountOut);

    /// @notice Apply a piecewise-linear scale to grow the amount out by shrinking the balance in
    /// @dev Should not be used with `_invalidateTokenIn1D` because it relies on `ctx.swap.balanceIn` which is modified here
    function _piecewiseLinearScaleBalanceIn1D(Context memory ctx, bytes calldata points) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, PiecewiseLinearScaleAmountsAlreadyComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        ctx.swap.balanceIn = (ctx.swap.balanceIn * _calcScaleNow(points)) >> 24;
    }

    /// @notice Apply a piecewise-linear scale to grow the amount in by shrinking the balance out
    /// @dev Should not be used with `_invalidateTokenOut1D` because it relies on `ctx.swap.balanceOut` which is modified here
    function _piecewiseLinearScaleBalanceOut1D(Context memory ctx, bytes calldata points) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, PiecewiseLinearScaleAmountsAlreadyComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        ctx.swap.balanceOut = (ctx.swap.balanceOut * _calcScaleNow(points)) >> 24;
    }

    /// @notice Find the current interval and get linear weighted scale, returns initial or last scale for no matching interval
    /// @dev Relies on packing [5 bytes timestamp, 3 bytes scales[k], 2 bytes durations[k] ...], `durations.length == scales.length - 1`
    /// - (a) At least two points provided -> `args.length >= 13 bytes`
    /// - (b) Scale is 3 bytes -> `scale + 1 <= 2 ** 24`
    /// - (c) Scale is 3 bytes and duration is 2 bytes -> `scale * duration < 2 ** 40`
    function _calcScaleNow(bytes calldata args) private view returns (uint256 scale) {
        unchecked {
            uint256 start = args.parseStartTimestamp();

            // Shift for 5 bytes: [5 bytes timestamp], then read 3 bytes at each 5 bytes slot with `parsePointScale`
            bytes calldata scales = args.slice(5);
            // Shift for 8 bytes: [5 bytes timestamp, 3 bytes scales[0]], then read 2 bytes at each 5 bytes slot with `parseIntervalDuration`
            bytes calldata durations = args.slice(8);

            // max == durations.length == scales.length - 1
            uint256 max = args.length / 5 - 1; // No underflow by (a)

            // Decrease time left instead of start and durations summation
            uint256 timeLeft = block.timestamp;

            // Early exit: scaling starts in future, return initial scale
            if (timeLeft <= start) return scales.parsePointScale(0) + 1; // No overflow by (b)
            timeLeft -= start; // No underflow by the check above

            uint256 num = 0;
            while (durations.parseIntervalDuration(num) < timeLeft) {
                timeLeft -= durations.parseIntervalDuration(num); // No underflow by the check above and resulting `timeLeft > 0`

                // Exit: durations[max] does not exist, last scaling interval in past, return last scale
                if (++num == max) return scales.parsePointScale(max) + 1; // No overflow by (b)
            }

            // durations[num] >= timeLeft > 0 -> `duration != 0`, later division is safe
            uint256 duration = durations.parseIntervalDuration(num);

            // Scale is in [1; 2 ** 24] range by the averaging property + (b)
            scale = (timeLeft * scales.parsePointScale(num + 1) + (duration - timeLeft) * scales.parsePointScale(num)) / duration + 1; // No overflow by (c)
        }
    }
}
