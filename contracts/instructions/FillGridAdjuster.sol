// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice FillGridAdjusterBalanceIn opcode, balance in surcharge based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]; has a virtual endpoint (BPS; 0)
/// @dev Placement before or after InvalidateTokenOut selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
library FillGridAdjusterBalanceIn {
    using Math for uint256;

    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridAdjusterNoPoints();
    error FillGridAdjusterMismatchInputLengths();
    error FillGridAdjusterInvalidGridStart();
    error FillGridAdjusterBpsOutOfRange();
    error FillGridAdjusterNotMonotonic();

    Opcode constant opcode = Opcode.FillGridAdjusterBalanceIn;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridAdjusterNoPoints());
        require(fillBps[0] == 0, FillGridAdjusterInvalidGridStart());

        ptr = ptrStart.pushHeader(opcode);

        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridAdjusterNotMonotonic());
            require(uint256(fillBps[i - 1]) * (BPS + adjustBps[i - 1]) < fillBps[i] * BPS, FillGridAdjusterNotMonotonic());
        }
        require(uint256(fillBps[fillBps.length - 1]) * (BPS + adjustBps[fillBps.length - 1]) < BPS * BPS, FillGridAdjusterNotMonotonic());

        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] < BPS && adjustBps[i] <= BPS, FillGridAdjusterBpsOutOfRange());
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

        uint256 balanceInR = ctx.swap.balanceIn;
        uint256 amountInR = balanceInR * BPS;
        (uint256 fillBps, uint256 adjustBps) = parsePoint(args, --count);

        uint256 balance;
        if (ctx.query.isExactIn) {
            if (ctx.swap.amountIn >= ctx.swap.balanceIn) return;

            uint256 balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
            uint256 amountInL = fillBps * balanceInL;
            uint256 amountIn = ctx.swap.amountIn * BPS;

            while (amountIn < amountInL) {
                (balanceInR, amountInR) = (balanceInL, amountInL);
                (fillBps, adjustBps) = parsePoint(args, --count);
                balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
                amountInL = fillBps * balanceInL;
            }

            // Linear approximation (amountInL, balanceInL) (amountInR, balanceInR) for amountIn
            balance = ((amountIn - amountInL) * balanceInR + (amountInR - amountIn) * balanceInL).ceilDiv(amountInR - amountInL);
        } else {
            if (ctx.swap.amountOut >= ctx.swap.balanceOut) return;

            uint256 balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
            uint256 amountInL = fillBps * balanceInL;
            uint256 amountOut = ctx.swap.amountOut * BPS;

            while (amountOut < fillBps * ctx.swap.balanceOut) {
                (balanceInR, amountInR) = (balanceInL, amountInL);
                (fillBps, adjustBps) = parsePoint(args, --count);
                balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
                amountInL = fillBps * balanceInL;
            }

            // Linear approximation (amountInL, balanceInL) (amountInR, balanceInR) for amountIn
            // Consider `amountIn = amountOut * balance / balanceOut`
            balance = Math.mulDiv(
                amountInR * balanceInL - amountInL * balanceInR,
                ctx.swap.balanceOut,
                (amountInR - amountInL) * ctx.swap.balanceOut + amountOut * (balanceInL - balanceInR),
                Math.Rounding.Ceil
            );
        }

        ctx.swap.surcharge += balance - ctx.swap.balanceIn;
        ctx.swap.balanceIn = balance;
    }
}

/// @notice FillGridAdjusterBalanceOut opcode, balance out surcharge based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]; has a virtual endpoint (BPS; 0)
/// @dev Placement before or after InvalidateTokenIn selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
library FillGridAdjusterBalanceOut {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridAdjusterNoPoints();
    error FillGridAdjusterMismatchInputLengths();
    error FillGridAdjusterInvalidGridStart();
    error FillGridAdjusterBpsOutOfRange();
    error FillGridAdjusterNotMonotonic();

    Opcode constant opcode = Opcode.FillGridAdjusterBalanceOut;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridAdjusterNoPoints());
        require(fillBps[0] == 0, FillGridAdjusterInvalidGridStart());

        ptr = ptrStart.pushHeader(opcode);

        for (uint256 i = 1; i < fillBps.length; i++) {
            require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridAdjusterNotMonotonic());
            // Balance out may grow by at most one per unit of amount out for any surcharge, otherwise its rounding breaks exactOut monotonicity
            require(
                (uint256(adjustBps[i - 1]) + fillBps[i - 1]) * BPS + uint256(adjustBps[i]) * fillBps[i - 1]
                    <= (uint256(adjustBps[i]) + fillBps[i]) * BPS + uint256(adjustBps[i - 1]) * fillBps[i],
                FillGridAdjusterNotMonotonic()
            );
        }

        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] < BPS && adjustBps[i] <= BPS, FillGridAdjusterBpsOutOfRange());
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

        // Rescale balanceOut for `scale * (BPS + adjustBps) / BPS`
        // Node balance out is kept unrounded as `numerator * BPS / denominator`, all nodes share the numerator
        uint256 base = (ctx.swap.balanceOut + ctx.swap.surcharge) * BPS;
        uint256 numerator = ctx.swap.balanceOut * (ctx.swap.balanceOut + ctx.swap.surcharge);
        uint256 denominatorR = base;
        uint256 amountInR = ctx.swap.balanceIn * BPS;
        (uint256 fillBps, uint256 adjustBps) = parsePoint(args, --count);
        uint256 denominatorL = base + ctx.swap.surcharge * adjustBps;

        uint256 balance;
        if (ctx.query.isExactIn) {
            if (ctx.swap.amountIn >= ctx.swap.balanceIn || ctx.swap.balanceOut == 0) return;

            uint256 amountInL = fillBps * ctx.swap.balanceIn;
            uint256 amountIn = ctx.swap.amountIn * BPS;

            while (amountIn < amountInL) {
                (denominatorR, amountInR) = (denominatorL, amountInL);
                (fillBps, adjustBps) = parsePoint(args, --count);
                denominatorL = base + ctx.swap.surcharge * adjustBps;
                amountInL = fillBps * ctx.swap.balanceIn;
            }

            // Hyperbolic approximation (amountInL, balanceOutL) (amountInR, balanceOutR) for amountIn
            // Inverted linear `((amountIn - amountInL) / balanceOutR + (amountInR - amountIn) / balanceOutL) / (amountInR - amountInL)`
            // The denominator is linear by amountIn, rounding it up keeps balance in favor of maker
            balance = Math.mulDiv(
                numerator,
                BPS,
                denominatorL - Math.mulDiv(denominatorL - denominatorR, amountIn - amountInL, amountInR - amountInL)
            );
        } else {
            if (ctx.swap.amountOut >= ctx.swap.balanceOut) return;

            uint256 fillR = BPS;

            while (ctx.swap.amountOut * denominatorL < fillBps * numerator) {
                (denominatorR, fillR) = (denominatorL, fillBps);
                (fillBps, adjustBps) = parsePoint(args, --count);
                denominatorL = base + ctx.swap.surcharge * adjustBps;
            }

            // Hyperbolic approximation (amountInL, balanceOutL) (amountInR, balanceOutR) for amountIn
            // Inverted linear `((amountIn - amountInL) / balanceOutR + (amountInR - amountIn) / balanceOutL) / (amountInR - amountInL)`
            // Consider `amountIn = amountOut * balanceIn / balance`, then balance is linear by amountOut and rounded once
            balance = Math.mulDiv(
                numerator * (fillR - fillBps) + ctx.swap.amountOut * (denominatorL - denominatorR),
                BPS,
                fillR * denominatorL - fillBps * denominatorR
            );
        }

        ctx.swap.surcharge += ctx.swap.balanceOut - balance;
        ctx.swap.balanceOut = balance;
    }
}
