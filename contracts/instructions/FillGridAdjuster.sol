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

/// @notice FillGridAdjuster opcode, price adjustment based on fill percent
/// @dev Encoding: [bool adjustIn, [uint24 fillBps, uint24 adjustBps] * points.length]; has a virtual endpoint (BPS; 0)
/// @dev Relies on the surcharge being final; no additional adjustments should be applied after this opcode
/// @dev Should be applied after InvalidateTokenOut for `adjustIn = true` or InvalidateTokenIn for `adjustIn = false`
///   due to the `amount >= balance` exit branch relies on balance being final
library FillGridAdjuster {
    using Math for uint256;

    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridAdjusterNoPoints();
    error FillGridAdjusterMismatchInputLengths();
    error FillGridAdjusterInvalidGridStart();
    error FillGridAdjusterBpsOutOfRange();
    error FillGridAdjusterNotMonotonic();

    Opcode constant opcode = Opcode.FillGridAdjuster;

    uint256 constant BPS = 1e7;

    function sizeOf(uint256 fillBpsLen, uint256 adjustBpsLen) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + fillBpsLen * 3 + adjustBpsLen * 3;
    }

    function build(bool adjustIn, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps.length, adjustBps.length)), adjustIn, fillBps, adjustBps).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool adjustIn,
        uint24[] memory fillBps,
        uint24[] memory adjustBps
    ) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridAdjusterNoPoints());
        require(fillBps[0] == 0, FillGridAdjusterInvalidGridStart());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(adjustIn, 0));

        if (adjustIn) {
            for (uint256 i = 1; i < fillBps.length; i++) {
                require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridAdjusterNotMonotonic());
                require((BPS + adjustBps[i - 1]) * fillBps[i - 1] < BPS * fillBps[i], FillGridAdjusterNotMonotonic());
            }
            require(
                uint256(fillBps[fillBps.length - 1]) * (BPS + adjustBps[fillBps.length - 1]) < BPS * BPS,
                FillGridAdjusterNotMonotonic()
            );
        } else {
            for (uint256 i = 1; i < fillBps.length; i++) {
                require(fillBps[i - 1] < fillBps[i] && adjustBps[i - 1] >= adjustBps[i], FillGridAdjusterNotMonotonic());
                require(
                    BPS * adjustBps[i - 1] + BPS * fillBps[i - 1] + uint256(adjustBps[i]) * fillBps[i - 1]
                        <= BPS * adjustBps[i] + BPS * fillBps[i] + uint256(adjustBps[i - 1]) * fillBps[i],
                    FillGridAdjusterNotMonotonic()
                );
            }
        }

        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] < BPS && adjustBps[i] <= BPS, FillGridAdjusterBpsOutOfRange());
            ptr = ptr.push(fillBps[i], 3).push(adjustBps[i], 3);
        }
        ptrStart.patchLength(ptr);
    }

    function parsePoint(bytes calldata args, uint256 i) internal pure returns (uint24 fillBps, uint24 adjustBps) {
        unchecked {
            fillBps = args.at(1 + i * 6).asU24();
            adjustBps = args.at(1 + i * 6 + 3).asU24();
        }
    }

    function parseHeader(bytes calldata args) internal pure returns (bool adjustIn, uint256 count) {
        adjustIn = args.at(0).asBool(0);
        count = (args.length - 1) / 6;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (bool adjustIn, uint256 count) = parseHeader(args);

        if (adjustIn) {
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
        } else {
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
}
