// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";

library PiecewiseLinearScaleArgsBuilder {
    error PiecewiseLinearScaleMismatchInputLengths();
    error PiecewiseLinearScaleNotEnoughPointsToBuildPiece();
    error PiecewiseLinearScaleUnorderedPoints();

    /// @notice Build instruction arguments for PiecewiseLinearScale
    /// @param timestamps Point timestamps, strictly ordered
    /// @param scales Point values at specified timestamps, `scale = (scales[n] + 1) / 2 ** 24`
    /// @return args Packed bytes for inclusion in program bytecode (8 bytes per point)
    function build(uint40[] memory timestamps, uint24[] memory scales) internal pure returns (bytes memory) {
        require(timestamps.length == scales.length, PiecewiseLinearScaleMismatchInputLengths());
        require(timestamps.length >= 2, PiecewiseLinearScaleNotEnoughPointsToBuildPiece());

        for (uint256 i = 1; i < timestamps.length; i++) {
            require(timestamps[i - 1] < timestamps[i], PiecewiseLinearScaleUnorderedPoints());
        }

        bytes memory code = new bytes(timestamps.length * 8);
        for (uint256 i; i < timestamps.length; i++) {
            assembly ("memory-safe") {
                let ptr := add(code, add(32, mul(i, 8)))
                let start := shl(216, mload(add(timestamps, add(32, mul(i, 32)))))
                let scale := shl(232, mload(add(scales, add(32, mul(i, 32)))))
                mstore(ptr, or(mload(ptr), or(start, shr(40, scale))))
            }
        }

        return code;
    }

    /// @notice Apply scale to the value
    /// @dev Matches the scaling in opcodes, note the `1` is added in `_calcScaleNow`
    function scaleValue(uint256 value, uint24 scale) internal pure returns (uint256 scaled) {
        scaled = (value * (uint256(scale) + 1)) >> 24;
    }

    /// @notice Unscale value back to 1.0 scale rounding up
    /// @dev Use to calculate order balances from target balance at specific scale (e.g. lowest scale)
    /// @dev Holds `scaleValue(unscaled, scale) == value`
    function unscaleValue(uint256 value, uint24 scale) internal pure returns (uint256 unscaled) {
        unscaled = ((value << 24) + scale) / (uint256(scale) + 1);
    }

    /// @notice Parse specific point timestamp
    function pointTs(bytes calldata args, uint256 n) internal pure returns (uint40 ts) {
        assembly {
            ts := shr(216, calldataload(add(args.offset, mul(n, 8))))
        }
    }

    /// @notice Parse specific point scale
    function pointScale(bytes calldata args, uint256 n) internal pure returns (uint24 scale) {
        assembly {
            scale := shr(232, calldataload(add(args.offset, add(mul(n, 8), 5))))
        }
    }
}

/**
 * @notice Piecewise Linear Scale instruction for time-based linear price decay/rise
 * @dev Implements a balance scaling for linearly changing scale value
 * - Designed to be used after balances set and before a swap instruction
 * - Applies time-based scaling to the balances
 * - Could be used for complex auctions with periods of price increase and decrease
 * - Applied at specified time periods, does not affect price out of the boundaries
 *
 * Example usage:
 * 1. Balances set to 1000e18 : 2000e18
 * 2. _piecewiseLinearScaleBalanceIn1D is used with points [(now, 0.5), (now + 1000, 0.7), (now + 2000, 0.3)]
 * 3. At start balances would be threated as 500e18 : 2000e18 then linearly go to 700e18 : 2000e18 and later to 300e18 : 2000e18
 * 4. Swap instruction calculates amounts based on updated balances
 * 
 * @dev Integration Notes
 * - Scaling is applied to token balances (reserves), not the amounts, this follows Exact In/Out Symmetry SwapVM Invariant
 * - Scaling basis points are 2 ** 24 (comparing to 10 ** 7 in Fusion), this uses the computation field efficiently
 * - Scaling range is (0; 1] (comparing to (~0.373; 1] in Fusion), this contributes to instruction generalization to be not bounded by case-specific limitations
 * - Interval is chosen using binary search instead of looping over each, this contributes to instruction generalization allowing more intervals
 * - The price adjustment is applied only at specified time ranges to allow multiple adjesment insructions apply at different time ranges without forced overlap
 * - For dutch auction selling specified amount, the order balance would not equal the amount, the amount should be reached as a result of final scaling,
 *   the `unscaleValue(amount, finalScale)` provides the value which would result in desired amount after scaling
 * - The instruction accepts array of points, each point is 8 bytes: 5 bytes (timestamp) + 3 bytes (scale - 1)
 */
contract PiecewiseLinearScale {
    using PiecewiseLinearScaleArgsBuilder for bytes;

    error PiecewiseLinearScaleShouldBeAppliedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);

    /// @notice Apply a piecewise-linear scale to grow the amount out by shrinking the balance in
    /// @dev Should not be used with _invalidateTokenIn1D because it relies on ctx.swap.balanceIn which is modified here
    function _piecewiseLinearScaleBalanceIn1D(Context memory ctx, bytes calldata points) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, PiecewiseLinearScaleShouldBeAppliedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        ctx.swap.balanceIn = (ctx.swap.balanceIn * _calcScaleNow(points)) >> 24;
    }

    /// @notice Apply a piecewise-linear scale to grow the amount in by shrinking the balance out
    /// @dev Should not be used with _invalidateTokenOut1D because it relies on ctx.swap.balanceOut which is modified here
    function _piecewiseLinearScaleBalanceOut1D(Context memory ctx, bytes calldata points) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, PiecewiseLinearScaleShouldBeAppliedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        ctx.swap.balanceOut = (ctx.swap.balanceOut * _calcScaleNow(points)) >> 24;
    }

    /// @dev The function relies on point are strictly ordered and there are at least two points
    function _calcScaleNow(bytes calldata points) private view returns (uint256 scale) {
        uint256 max = points.length / 8 - 1;

        uint256 blockTs = block.timestamp;
        if (points.pointTs(max) < blockTs) {
            return 1 << 24;
        }
        if (points.pointTs(0) > blockTs) {
            return 1 << 24;
        }

        uint256 num;
        while (num < max) {
            unchecked {
                uint256 mid = (num + max) / 2;
                if (points.pointTs(mid) <= blockTs) {
                    num = mid + 1;
                } else {
                    max = mid;
                }
            }
        }

        uint256 currentPointTs = points.pointTs(num - 1);
        uint256 nextPointTs = points.pointTs(num);

        // scale is in [1; 2 ** 24] range
        scale = (
            (blockTs - currentPointTs) * points.pointScale(num) +
            (nextPointTs - blockTs) * points.pointScale(num - 1)
        ) / (nextPointTs - currentPointTs) + 1;
    }
}
