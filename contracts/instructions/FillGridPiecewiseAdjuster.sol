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

/// @notice FillGridPiecewiseAdjusterBalanceIn opcode, taker piecewise-linear discount based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]
/// @dev Placement before or after InvalidateTokenOut selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional discounts should be applied after this opcode
library FillGridPiecewiseAdjusterBalanceIn {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    error FillGridPiecewiseAdjusterNoPoints();
    error FillGridPiecewiseAdjusterMismatchInputLengths();
    error FillGridPiecewiseAdjusterBpsOutOfRange();
    error FillGridPiecewiseAdjusterNonAscendingFillBps();
    error FillGridPiecewiseAdjusterIncreasingAdjustBps();
    error FillGridPiecewiseAdjusterDecreasingFillCapacity();
    error FillGridPiecewiseAdjusterInvalidEndpoints();

    Opcode constant opcode = Opcode.FillGridPiecewiseAdjusterBalanceIn;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridPiecewiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridPiecewiseAdjusterNoPoints());
        require(
            fillBps[0] == 0 && adjustBps[0] == BPS && fillBps[fillBps.length - 1] == BPS,
            FillGridPiecewiseAdjusterInvalidEndpoints()
        );

        ptr = ptrStart.pushHeader(opcode).push(fillBps[0], 3).push(adjustBps[0], 3);
        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i] <= BPS && adjustBps[i] <= BPS, FillGridPiecewiseAdjusterBpsOutOfRange());
            require(fillBps[i - 1] < fillBps[i], FillGridPiecewiseAdjusterNonAscendingFillBps());
            require(adjustBps[i - 1] >= adjustBps[i], FillGridPiecewiseAdjusterIncreasingAdjustBps());
            // Fill capacity must remain nondecreasing throughout the piece.
            require(
                uint256(adjustBps[i]) * (fillBps[i] - fillBps[i - 1])
                    >= uint256(fillBps[i]) * (adjustBps[i - 1] - adjustBps[i]),
                FillGridPiecewiseAdjusterDecreasingFillCapacity()
            );
            ptr = ptr.push(fillBps[i], 3).push(adjustBps[i], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parsePoint(bytes calldata args, uint256 i) internal pure returns (uint24 fillBps, uint24 adjustBps) {
        fillBps = args.at(i * 6).asU24();
        adjustBps = args.at(i * 6 + 3).asU24();
    }

    function parsePointsCount(bytes calldata args) internal pure returns (uint256 count) {
        count = args.length / 6;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 pointIndex = parsePointsCount(args) - 1;

        uint24 fillBps;
        uint24 adjustBps;
        (fillBps, adjustBps) = parsePoint(args, pointIndex);

        uint256 lastPointIndex = pointIndex;
        uint256 surcharge = ctx.swap.surcharge * adjustBps / BPS;
        uint256 discount;

        if (ctx.query.isExactIn) {
            discount = ctx.swap.surcharge - surcharge;
            while (pointIndex > 0 && ctx.swap.amountIn < (ctx.swap.balanceIn - discount) * fillBps / BPS) {
                (fillBps, adjustBps) = parsePoint(args, --pointIndex);
                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;
            }

            if (pointIndex < lastPointIndex) {
                (uint24 upperFillBps, uint24 upperAdjustBps) = parsePoint(args, pointIndex + 1);
                uint256 upperSurcharge = ctx.swap.surcharge * upperAdjustBps / BPS;
                uint256 upperBalanceIn = ctx.swap.balanceIn - (ctx.swap.surcharge - upperSurcharge);
                uint256 currentFillBps =
                    solveExactIn(ctx, fillBps, ctx.swap.balanceIn - discount, upperFillBps, upperBalanceIn);

                surcharge = (
                    surcharge * (upperFillBps - currentFillBps) + upperSurcharge * (currentFillBps - fillBps)
                ) / (upperFillBps - fillBps);
            }
        } else {
            while (pointIndex > 0 && ctx.swap.amountOut < ctx.swap.balanceOut * fillBps / BPS) {
                (fillBps, adjustBps) = parsePoint(args, --pointIndex);
                surcharge = ctx.swap.surcharge * adjustBps / BPS;
            }

            if (pointIndex < lastPointIndex) {
                (uint24 upperFillBps, uint24 upperAdjustBps) = parsePoint(args, pointIndex + 1);
                uint256 upperSurcharge = ctx.swap.surcharge * upperAdjustBps / BPS;
                uint256 currentFillBps = ctx.swap.amountOut * BPS / ctx.swap.balanceOut;
                if (currentFillBps < fillBps) currentFillBps = fillBps;

                surcharge = (
                    surcharge * (upperFillBps - currentFillBps) + upperSurcharge * (currentFillBps - fillBps)
                ) / (upperFillBps - fillBps);
            }
        }

        discount = ctx.swap.surcharge - surcharge;
        ctx.swap.surcharge = surcharge;
        ctx.swap.balanceIn -= discount;
    }

    /// @dev Solves `balanceDelta * fillBps ** 2 - beta * fillBps + amountIn * BPS * width = 0`,
    ///   where balanceIn is linearly interpolated between exact grid-point balances.
    ///   The smaller root lies inside the piece selected by exec and is rounded down.
    function solveExactIn(
        Context memory ctx,
        uint24 lowerFillBps,
        uint256 lowerBalanceIn,
        uint24 upperFillBps,
        uint256 upperBalanceIn
    ) private pure returns (uint256 fillBps) {
        uint24 width = upperFillBps - lowerFillBps;
        uint256 balanceDelta = lowerBalanceIn - upperBalanceIn;

        if (balanceDelta == 0) {
            fillBps = ctx.swap.amountIn * BPS / lowerBalanceIn;
        } else {
            uint256 beta = lowerBalanceIn * width + balanceDelta * lowerFillBps;
            uint256 fourAC = 4 * balanceDelta * ctx.swap.amountIn * BPS * width;
            uint256 discriminant = beta * beta - fourAC;
            fillBps = (beta - discriminant.sqrt(Math.Rounding.Ceil)) / (2 * balanceDelta);
        }

        if (fillBps < lowerFillBps) fillBps = lowerFillBps;
    }
}

/// @notice FillGridPiecewiseAdjusterBalanceOut opcode, taker piecewise-linear discount based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]
/// @dev Placement before or after InvalidateTokenIn selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional discounts should be applied after this opcode
library FillGridPiecewiseAdjusterBalanceOut {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    error FillGridPiecewiseAdjusterNoPoints();
    error FillGridPiecewiseAdjusterMismatchInputLengths();
    error FillGridPiecewiseAdjusterBpsOutOfRange();
    error FillGridPiecewiseAdjusterNonAscendingFillBps();
    error FillGridPiecewiseAdjusterIncreasingAdjustBps();
    error FillGridPiecewiseAdjusterInvalidEndpoints();

    Opcode constant opcode = Opcode.FillGridPiecewiseAdjusterBalanceOut;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridPiecewiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridPiecewiseAdjusterNoPoints());
        require(
            fillBps[0] == 0 && adjustBps[0] == BPS && fillBps[fillBps.length - 1] == BPS,
            FillGridPiecewiseAdjusterInvalidEndpoints()
        );

        ptr = ptrStart.pushHeader(opcode).push(fillBps[0], 3).push(adjustBps[0], 3);
        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i] <= BPS && adjustBps[i] <= BPS, FillGridPiecewiseAdjusterBpsOutOfRange());
            require(fillBps[i - 1] < fillBps[i], FillGridPiecewiseAdjusterNonAscendingFillBps());
            require(adjustBps[i - 1] >= adjustBps[i], FillGridPiecewiseAdjusterIncreasingAdjustBps());
            ptr = ptr.push(fillBps[i], 3).push(adjustBps[i], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parsePoint(bytes calldata args, uint256 i) internal pure returns (uint24 fillBps, uint24 adjustBps) {
        fillBps = args.at(i * 6).asU24();
        adjustBps = args.at(i * 6 + 3).asU24();
    }

    function parsePointsCount(bytes calldata args) internal pure returns (uint256 count) {
        count = args.length / 6;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 pointIndex = parsePointsCount(args) - 1;

        uint24 fillBps;
        uint24 adjustBps;
        (fillBps, adjustBps) = parsePoint(args, pointIndex);

        uint256 lastPointIndex = pointIndex;
        uint256 surcharge = ctx.swap.surcharge * adjustBps / BPS;
        uint256 discount;

        if (ctx.query.isExactIn) {
            while (pointIndex > 0 && ctx.swap.amountIn < ctx.swap.balanceIn * fillBps / BPS) {
                (fillBps, adjustBps) = parsePoint(args, --pointIndex);
                surcharge = ctx.swap.surcharge * adjustBps / BPS;
            }

            if (pointIndex < lastPointIndex) {
                (uint24 upperFillBps, uint24 upperAdjustBps) = parsePoint(args, pointIndex + 1);
                uint256 upperSurcharge = ctx.swap.surcharge * upperAdjustBps / BPS;
                uint256 currentFillBps = ctx.swap.amountIn * BPS / ctx.swap.balanceIn;
                if (currentFillBps < fillBps) currentFillBps = fillBps;

                surcharge = (
                    surcharge * (upperFillBps - currentFillBps) + upperSurcharge * (currentFillBps - fillBps)
                ) / (upperFillBps - fillBps);
            }
        } else {
            discount = ctx.swap.surcharge - surcharge;
            while (pointIndex > 0 && ctx.swap.amountOut < (ctx.swap.balanceOut + discount) * fillBps / BPS) {
                (fillBps, adjustBps) = parsePoint(args, --pointIndex);
                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;
            }

            if (pointIndex < lastPointIndex) {
                (uint24 upperFillBps, uint24 upperAdjustBps) = parsePoint(args, pointIndex + 1);
                uint256 upperSurcharge = ctx.swap.surcharge * upperAdjustBps / BPS;
                uint256 upperBalanceOut = ctx.swap.balanceOut + (ctx.swap.surcharge - upperSurcharge);
                uint256 currentFillBps =
                    solveExactOut(ctx, fillBps, ctx.swap.balanceOut + discount, upperFillBps, upperBalanceOut);

                surcharge = (
                    surcharge * (upperFillBps - currentFillBps) + upperSurcharge * (currentFillBps - fillBps)
                ) / (upperFillBps - fillBps);
            }
        }

        discount = ctx.swap.surcharge - surcharge;
        ctx.swap.balanceOut += discount;
        ctx.swap.surcharge = surcharge;
    }

    /// @dev Solves for `distanceBps = upperFillBps - fillBps`:
    ///   `balanceDelta * distanceBps ** 2 - beta * distanceBps + capacityDelta * width = 0`.
    ///   The smaller distance root is rounded up so fillBps is rounded down.
    function solveExactOut(
        Context memory ctx,
        uint24 lowerFillBps,
        uint256 lowerBalanceOut,
        uint24 upperFillBps,
        uint256 upperBalanceOut
    ) private pure returns (uint256 fillBps) {
        uint24 width = upperFillBps - lowerFillBps;
        uint256 balanceDelta = upperBalanceOut - lowerBalanceOut;

        if (balanceDelta == 0) {
            fillBps = ctx.swap.amountOut * BPS / lowerBalanceOut;
        } else {
            uint256 beta = upperBalanceOut * width + balanceDelta * upperFillBps;
            uint256 capacityDelta = upperBalanceOut * upperFillBps - ctx.swap.amountOut * BPS;
            uint256 fourAC = 4 * balanceDelta * capacityDelta * width;
            uint256 discriminant = beta * beta - fourAC;
            uint256 distanceBps = (beta - discriminant.sqrt()).ceilDiv(2 * balanceDelta);
            fillBps = upperFillBps - distanceBps;
        }

        if (fillBps < lowerFillBps) fillBps = lowerFillBps;
    }
}
