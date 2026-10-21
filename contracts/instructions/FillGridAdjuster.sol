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

/// @notice FillGridAdjusterSell opcode, balance in surcharge based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]; has a virtual endpoint (BPS; 0)
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
/// @dev The opcode is expected to be applied after InvalidateTokenSell; amount >= balance exit branch relies on balance being final
library FillGridAdjusterSell {
    using Math for uint256;

    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridAdjusterNoPoints();
    error FillGridAdjusterMismatchInputLengths();
    error FillGridAdjusterInvalidGridStart();
    error FillGridAdjusterBpsOutOfRange();
    error FillGridAdjusterNotMonotonic();

    Opcode constant opcode = Opcode.FillGridAdjusterSell;

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
            require((BPS + adjustBps[i - 1]) * fillBps[i - 1] < BPS * fillBps[i], FillGridAdjusterNotMonotonic());
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

        uint256 balance;
        if (ctx.query.isExactIn) {
            if (ctx.swap.amountIn >= ctx.swap.balanceIn || ctx.swap.surcharge == 0) return;
            (uint256 fillBps, uint256 adjustBps) = parsePoint(args, --count);

            uint256 balanceInR = ctx.swap.balanceIn;
            uint256 balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;

            uint256 amountIn = ctx.swap.amountIn * BPS;
            uint256 amountInR = balanceInR * BPS;
            uint256 amountInL = fillBps * balanceInL;

            while (amountIn < amountInL) {
                (balanceInR, amountInR) = (balanceInL, amountInL);
                (fillBps, adjustBps) = parsePoint(args, --count);
                balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
                amountInL = fillBps * balanceInL;
            }

            // Linear approximation (amountInL, balanceInL) (amountInR, balanceInR) for amountIn
            balance = ((amountIn - amountInL) * balanceInR + (amountInR - amountIn) * balanceInL).ceilDiv(amountInR - amountInL);
        } else {
            if (ctx.swap.amountOut >= ctx.swap.balanceOut || ctx.swap.surcharge == 0) return;
            uint256 fillBpsR = BPS;
            (uint256 fillBpsL, uint256 adjustBps) = parsePoint(args, --count);

            // Known precision loss in balanceInL calculations leading to exactOut(x) > exactOut(x+1) for dust
            uint256 balanceInR = ctx.swap.balanceIn;
            uint256 balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;

            uint256 amountOut = ctx.swap.amountOut * BPS;

            while (amountOut < fillBpsL * ctx.swap.balanceOut) {
                (balanceInR, fillBpsR) = (balanceInL, fillBpsL);
                (fillBpsL, adjustBps) = parsePoint(args, --count);
                balanceInL = ctx.swap.balanceIn + ctx.swap.surcharge * adjustBps / BPS;
            }

            // Linear approximation (amountInL, balanceInL) (amountInR, balanceInR) for amountIn
            // Consider `amountInL/R = fillBpsL/R * balanceInL/R`
            // Consider `amountIn = amountOut * balance / balanceOut`
            balance = Math.mulDiv(
                balanceInL * balanceInR,
                ctx.swap.balanceOut * (fillBpsR - fillBpsL),
                (fillBpsR * balanceInR - fillBpsL * balanceInL) * ctx.swap.balanceOut + amountOut * (balanceInL - balanceInR),
                Math.Rounding.Ceil
            );
        }

        ctx.swap.surcharge += balance - ctx.swap.balanceIn;
        ctx.swap.balanceIn = balance;
    }
}

/// @notice FillGridAdjusterBuy opcode, balance out surcharge based on fill percent
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * points.length]; has a virtual endpoint (BPS; 0)
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
/// @dev The opcode is expected to be applied after InvalidateTokenBuy; amount >= balance exit branch relies on balance being final
library FillGridAdjusterBuy {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridAdjusterNoPoints();
    error FillGridAdjusterMismatchInputLengths();
    error FillGridAdjusterInvalidGridStart();
    error FillGridAdjusterBpsOutOfRange();
    error FillGridAdjusterNotMonotonic();

    Opcode constant opcode = Opcode.FillGridAdjusterBuy;

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
            require(
                BPS * adjustBps[i - 1] + BPS * fillBps[i - 1] + uint256(adjustBps[i]) * fillBps[i - 1]
                    <= BPS * adjustBps[i] + BPS * fillBps[i] + uint256(adjustBps[i - 1]) * fillBps[i],
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

        uint256 balance;
        if (ctx.query.isExactIn) {
            if (ctx.swap.amountIn >= ctx.swap.balanceIn || ctx.swap.surcharge == 0) return;
            (uint256 fillBps, uint256 adjustBps) = parsePoint(args, --count);

            // balanceOutR = rational(balanceOutNum * BPS, balanceOutDenomR)
            uint256 balanceOutNum = ctx.swap.balanceOut * (ctx.swap.balanceOut + ctx.swap.surcharge);
            uint256 balanceOutDenomR = (ctx.swap.balanceOut + ctx.swap.surcharge) * BPS;

            // Rescale balanceOut for `scale * (BPS + adjustBps) / BPS`
            uint256 balanceOutDenomL = ctx.swap.balanceOut * BPS + ctx.swap.surcharge * (BPS + adjustBps);

            uint256 amountIn = ctx.swap.amountIn * BPS;
            uint256 amountInR = ctx.swap.balanceIn * BPS;
            uint256 amountInL = fillBps * ctx.swap.balanceIn;

            while (amountIn < amountInL) {
                (balanceOutDenomR, amountInR) = (balanceOutDenomL, amountInL);
                (fillBps, adjustBps) = parsePoint(args, --count);
                balanceOutDenomL = ctx.swap.balanceOut * BPS + ctx.swap.surcharge * (BPS + adjustBps);
                amountInL = fillBps * ctx.swap.balanceIn;
            }

            // Hyperbolic approximation (amountInL, balanceOutL) (amountInR, balanceOutR) for amountIn
            // Inverted linear `((amountIn - amountInL) / balanceOutR + (amountInR - amountIn) / balanceOutL) / (amountInR - amountInL)`
            // The denominator is linear by amountIn, rounding it up keeps balance in favor of maker
            balance = balanceOutNum * BPS
                / (balanceOutDenomL - Math.mulDiv(balanceOutDenomL - balanceOutDenomR, amountIn - amountInL, amountInR - amountInL));
        } else {
            if (ctx.swap.amountOut >= ctx.swap.balanceOut || ctx.swap.surcharge == 0) return;
            uint256 fillBpsR = BPS;
            (uint256 fillBpsL, uint256 adjustBps) = parsePoint(args, --count);

            // balanceOutR = rational(balanceOutNum * BPS, balanceOutDenomR)
            uint256 balanceOutNum = ctx.swap.balanceOut * (ctx.swap.balanceOut + ctx.swap.surcharge);
            uint256 balanceOutDenomR = (ctx.swap.balanceOut + ctx.swap.surcharge) * BPS;

            // Rescale balanceOut for `scale * (BPS + adjustBps) / BPS`
            uint256 balanceOutDenomL = ctx.swap.balanceOut * BPS + ctx.swap.surcharge * (BPS + adjustBps);

            while (ctx.swap.amountOut * balanceOutDenomL < fillBpsL * balanceOutNum) {
                (balanceOutDenomR, fillBpsR) = (balanceOutDenomL, fillBpsL);
                (fillBpsL, adjustBps) = parsePoint(args, --count);
                balanceOutDenomL = ctx.swap.balanceOut * BPS + ctx.swap.surcharge * (BPS + adjustBps);
            }

            // Hyperbolic approximation (amountInL, balanceOutL) (amountInR, balanceOutR) for amountIn
            // Inverted linear `((amountIn - amountInL) / balanceOutR + (amountInR - amountIn) / balanceOutL) / (amountInR - amountInL)`
            // Consider `amountInL/R = fillBpsL/R * balanceIn`
            // Consider `amountIn = amountOut * balanceIn / balance`
            balance = Math.mulDiv(
                balanceOutNum * (fillBpsR - fillBpsL) + ctx.swap.amountOut * (balanceOutDenomL - balanceOutDenomR),
                BPS,
                fillBpsR * balanceOutDenomL - fillBpsL * balanceOutDenomR
            );
        }

        ctx.swap.surcharge += ctx.swap.balanceOut - balance;
        ctx.swap.balanceOut = balance;
    }
}
