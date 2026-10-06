// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice FillGridHyperwiseAdjusterBalanceIn opcode, taker piecewise-hyperbolic surcharge based on fill percent grid
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]
///   Has two virtual points (0; adjustBps[0]) and (BPS, 0)
/// @dev Placement before or after InvalidateTokenOut selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
library FillGridHyperwiseAdjusterBalanceIn {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridHyperwiseAdjusterNoPoints();
    error FillGridHyperwiseAdjusterMismatchInputLengths();
    error FillGridHyperwiseAdjusterInvalidGridStart();
    error FillGridHyperwiseAdjusterBpsOutOfRange();
    error FillGridHyperwiseAdjusterNotMonotonic();
    error FillGridHyperwiseAdjusterContextOverflow();

    Opcode constant opcode = Opcode.FillGridHyperwiseAdjusterBalanceIn;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridHyperwiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridHyperwiseAdjusterNoPoints());
        require(fillBps[0] > 0, FillGridHyperwiseAdjusterInvalidGridStart());

        ptr = ptrStart.pushHeader(opcode);

        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridHyperwiseAdjusterNotMonotonic());
        }

        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] < BPS && adjustBps[i] <= BPS, FillGridHyperwiseAdjusterBpsOutOfRange());
            ptr = ptr.push(fillBps[i], 3).push(adjustBps[i], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parsePoint(bytes calldata args, uint256 i) internal pure returns (uint24 fillBps, uint24 adjustBps) {
        unchecked {
            fillBps = args.at(i * 6).asU24();
            adjustBps = args.at(i * 6 + 3).asU24();
        }
    }

    function parsePointsCount(bytes calldata args) internal pure returns (uint256 count) {
        count = args.length / 6;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 count = parsePointsCount(args);
        uint256 bump;

        unchecked {
            if (ctx.query.isExactIn) {
                if (ctx.swap.amountIn >= ctx.swap.balanceIn) return;

                require(
                    ctx.swap.surcharge <= type(uint160).max
                        && ctx.swap.balanceIn <= type(uint160).max
                        && ctx.swap.amountIn <= type(uint160).max,
                    FillGridHyperwiseAdjusterContextOverflow()
                );

                uint256 fillBpsR = BPS; uint256 adjustBpsR; // Last point enforced as at 100% fill 0% adjustment
                (uint256 fillBpsL, uint256 adjustBpsL) = parsePoint(args, --count);

                while (count > 0 && ctx.swap.amountIn * BPS * BPS < (ctx.swap.balanceIn * BPS + ctx.swap.surcharge * adjustBpsL) * fillBpsL) {
                    (fillBpsR, adjustBpsR) = (fillBpsL, adjustBpsL);
                    (fillBpsL, adjustBpsL) = parsePoint(args, --count);
                }

                if (ctx.swap.amountIn * BPS * BPS < (ctx.swap.balanceIn * BPS + ctx.swap.surcharge * adjustBpsL) * fillBpsL) {
                    // Use the worst adjustment for fills smaller than first grid point
                    bump = ctx.swap.surcharge * adjustBpsL / BPS;
                } else {
                    // Curve `adjustBps = A / fillBps + (B - C) / BPS` satisfies (fillBpsL, adjustBpsL) and (fillBpsR, adjustBpsR) points 
                    // `A = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR / (fillBpsR - fillBpsL)`
                    // `B = adjustBpsR * fillBpsR * BPS / (fillBpsR - fillBpsL)`
                    // `C = adjustBpsL * fillBpsL * BPS / (fillBpsR - fillBpsL)`

                    // `fillBps = A * BPS / (adjustBps * BPS - B + C)`
                    // `fillBps = amountIn * BPS ** 2 / (balanceIn * BPS + surcharge * adjustBps)`
                    // `adjustBps = (A * balanceIn * BPS + amountIn * BPS * (B - C)) / (amountIn * BPS ** 2 - A * surcharge)`

                    // `bump = surcharge * adjustBps / BPS`
                    // `bump = surcharge * (A * balanceIn + amountIn * (B - C)) / (amountIn * BPS ** 2 - A * surcharge)`

                    uint256 length = fillBpsR - fillBpsL;
                    uint256 a = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR;
                    uint256 b = adjustBpsR * fillBpsR * BPS;
                    uint256 c = adjustBpsL * fillBpsL * BPS;

                    // Bump is surcharge part, round down
                    bump = Math.mulDiv(
                        ctx.swap.surcharge,
                        a * ctx.swap.balanceIn + b * ctx.swap.amountIn - c * ctx.swap.amountIn,
                        ctx.swap.amountIn * BPS * BPS * length - a * ctx.swap.surcharge
                    );
                }
            } else {
                if (ctx.swap.amountOut >= ctx.swap.balanceOut) return;

                require(
                    ctx.swap.surcharge <= type(uint160).max
                        && ctx.swap.balanceOut <= type(uint160).max
                        && ctx.swap.amountOut <= type(uint160).max,
                    FillGridHyperwiseAdjusterContextOverflow()
                );

                uint256 fillBpsR = BPS; uint256 adjustBpsR; // Last point enforced as at 100% fill 0% adjustment
                (uint256 fillBpsL, uint256 adjustBpsL) = parsePoint(args, --count);

                while (count > 0 && ctx.swap.amountOut * BPS < ctx.swap.balanceOut * fillBpsL) {
                    (fillBpsR, adjustBpsR) = (fillBpsL, adjustBpsL);
                    (fillBpsL, adjustBpsL) = parsePoint(args, --count);
                }

                if (ctx.swap.amountOut * BPS < ctx.swap.balanceOut * fillBpsL) {
                    // Use the worst adjustment for fills smaller than first grid point
                    bump = ctx.swap.surcharge * adjustBpsL / BPS;
                } else {
                    // `adjustBps = A / fillBps + (B - C) / BPS`
                    // `A = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR / (fillBpsR - fillBpsL)`
                    // `B = adjustBpsR * fillBpsR * BPS / (fillBpsR - fillBpsL)`
                    // `C = adjustBpsL * fillBpsL * BPS / (fillBpsR - fillBpsL)`

                    // `fillBps = A * BPS / (adjustBps * BPS - B + C)`
                    // `fillBps = amountOut * BPS / balanceOut`
                    // `adjustBps = (A * balanceOut + amountOut * (B - C)) / (amountOut * BPS)`

                    // `bump = surcharge * adjustBps / BPS`
                    // `bump = surcharge * (A * balanceOut + amountOut * (B - C)) / (amountOut * BPS ** 2)`

                    uint256 length = fillBpsR - fillBpsL;
                    uint256 a = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR;
                    uint256 b = adjustBpsR * fillBpsR * BPS;
                    uint256 c = adjustBpsL * fillBpsL * BPS;

                    // Bump is surcharge part, round down
                    bump = Math.mulDiv(
                        ctx.swap.surcharge,
                        a * ctx.swap.balanceOut + b * ctx.swap.amountOut - c * ctx.swap.amountOut,
                        ctx.swap.amountOut * BPS * BPS * length
                    );
                }
            }
        }

        ctx.swap.surcharge += bump;
        ctx.swap.balanceIn += bump;
    }
}

/// @notice FillGridHyperwiseAdjusterBalanceOut opcode, taker piecewise-hyperbolic surcharge based on fill percent grid
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]
///   Has two virtual points (0; adjustBps[0]) and (BPS, 0)
/// @dev Placement before or after InvalidateTokenIn selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
library FillGridHyperwiseAdjusterBalanceOut {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridHyperwiseAdjusterNoPoints();
    error FillGridHyperwiseAdjusterMismatchInputLengths();
    error FillGridHyperwiseAdjusterInvalidGridStart();
    error FillGridHyperwiseAdjusterBpsOutOfRange();
    error FillGridHyperwiseAdjusterNotMonotonic();
    error FillGridHyperwiseAdjusterContextOverflow();

    Opcode constant opcode = Opcode.FillGridHyperwiseAdjusterBalanceOut;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridHyperwiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridHyperwiseAdjusterNoPoints());
        require(fillBps[0] > 0, FillGridHyperwiseAdjusterInvalidGridStart());

        ptr = ptrStart.pushHeader(opcode);

        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridHyperwiseAdjusterNotMonotonic());
        }

        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] < BPS && adjustBps[i] <= BPS, FillGridHyperwiseAdjusterBpsOutOfRange());
            ptr = ptr.push(fillBps[i], 3).push(adjustBps[i], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parsePoint(bytes calldata args, uint256 i) internal pure returns (uint24 fillBps, uint24 adjustBps) {
        unchecked {
            fillBps = args.at(i * 6).asU24();
            adjustBps = args.at(i * 6 + 3).asU24();
        }
    }

    function parsePointsCount(bytes calldata args) internal pure returns (uint256 count) {
        count = args.length / 6;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 count = parsePointsCount(args);
        uint256 bump;

        unchecked {
            if (ctx.query.isExactIn) {
                if (ctx.swap.amountIn >= ctx.swap.balanceIn) return;

                require(
                    ctx.swap.surcharge <= type(uint160).max
                        && ctx.swap.balanceIn <= type(uint160).max
                        && ctx.swap.amountIn <= type(uint160).max,
                    FillGridHyperwiseAdjusterContextOverflow()
                );

                uint256 fillBpsR = BPS; uint256 adjustBpsR; // Last point enforced as at 100% fill 0% adjustment
                (uint256 fillBpsL, uint256 adjustBpsL) = parsePoint(args, --count);

                while (count > 0 && ctx.swap.amountIn * BPS < ctx.swap.balanceIn * fillBpsL) {
                    (fillBpsR, adjustBpsR) = (fillBpsL, adjustBpsL);
                    (fillBpsL, adjustBpsL) = parsePoint(args, --count);
                }

                if (ctx.swap.amountIn * BPS < ctx.swap.balanceIn * fillBpsL) {
                    // Use the worst adjustment for fills smaller than first grid point
                    bump = ctx.swap.surcharge * adjustBpsL / BPS;
                } else {
                    // Curve `adjustBps = A / fillBps + (B - C) / BPS` satisfies (fillBpsL, adjustBpsL) and (fillBpsR, adjustBpsR) points
                    // `A = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR / (fillBpsR - fillBpsL)`
                    // `B = adjustBpsR * fillBpsR * BPS / (fillBpsR - fillBpsL)`
                    // `C = adjustBpsL * fillBpsL * BPS / (fillBpsR - fillBpsL)`

                    // `fillBps = A * BPS / (adjustBps * BPS - B + C)`
                    // `fillBps = amountIn * BPS / balanceIn`
                    // `adjustBps = (A * balanceIn + amountIn * (B - C)) / (amountIn * BPS)`

                    // `bump = surcharge * adjustBps / BPS`
                    // `bump = surcharge * (A * balanceIn + amountIn * (B - C)) / (amountIn * BPS ** 2)`

                    uint256 length = fillBpsR - fillBpsL;
                    uint256 a = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR;
                    uint256 b = adjustBpsR * fillBpsR * BPS;
                    uint256 c = adjustBpsL * fillBpsL * BPS;

                    // Bump is surcharge part, round down
                    bump = Math.mulDiv(
                        ctx.swap.surcharge,
                        a * ctx.swap.balanceIn + b * ctx.swap.amountIn - c * ctx.swap.amountIn,
                        ctx.swap.amountIn * BPS * BPS * length
                    );
                }
            } else {
                if (ctx.swap.amountOut >= ctx.swap.balanceOut) return;

                require(
                    ctx.swap.surcharge <= ctx.swap.balanceOut
                        && ctx.swap.balanceOut <= type(uint160).max
                        && ctx.swap.amountOut <= type(uint160).max,
                    FillGridHyperwiseAdjusterContextOverflow()
                );

                uint256 fillBpsR = BPS; uint256 adjustBpsR; // Last point enforced as at 100% fill 0% adjustment
                (uint256 fillBpsL, uint256 adjustBpsL) = parsePoint(args, --count);

                while (count > 0 && ctx.swap.amountOut * BPS * BPS < (ctx.swap.balanceOut * BPS - ctx.swap.surcharge * adjustBpsL) * fillBpsL) {
                    (fillBpsR, adjustBpsR) = (fillBpsL, adjustBpsL);
                    (fillBpsL, adjustBpsL) = parsePoint(args, --count);
                }

                if (ctx.swap.amountOut * BPS * BPS < (ctx.swap.balanceOut * BPS - ctx.swap.surcharge * adjustBpsL) * fillBpsL) {
                    // Use the worst adjustment for fills smaller than first grid point
                    bump = ctx.swap.surcharge * adjustBpsL / BPS;
                } else {
                    // Curve `adjustBps = A / fillBps + (B - C) / BPS` satisfies (fillBpsL, adjustBpsL) and (fillBpsR, adjustBpsR) points
                    // `A = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR / (fillBpsR - fillBpsL)`
                    // `B = adjustBpsR * fillBpsR * BPS / (fillBpsR - fillBpsL)`
                    // `C = adjustBpsL * fillBpsL * BPS / (fillBpsR - fillBpsL)`

                    // `fillBps = A * BPS / (adjustBps * BPS - B + C)`
                    // `fillBps = amountOut * BPS ** 2 / (balanceOut * BPS - surcharge * adjustBps)`
                    // `adjustBps = (A * balanceOut * BPS + amountOut * BPS * (B - C)) / (amountOut * BPS ** 2 + A * surcharge)`

                    // `bump = surcharge * adjustBps / BPS`
                    // `bump = surcharge * (A * balanceOut + amountOut * (B - C)) / (amountOut * BPS ** 2 + A * surcharge)`

                    uint256 length = fillBpsR - fillBpsL;
                    uint256 a = (adjustBpsL - adjustBpsR) * fillBpsL * fillBpsR;
                    uint256 b = adjustBpsR * fillBpsR * BPS;
                    uint256 c = adjustBpsL * fillBpsL * BPS;

                    // Bump is surcharge part, round down
                    bump = Math.mulDiv(
                        ctx.swap.surcharge,
                        a * ctx.swap.balanceOut + b * ctx.swap.amountOut - c * ctx.swap.amountOut,
                        ctx.swap.amountOut * BPS * BPS * length + a * ctx.swap.surcharge
                    );
                }
            }
        }

        ctx.swap.surcharge += bump;
        ctx.swap.balanceOut -= bump;
    }
}
