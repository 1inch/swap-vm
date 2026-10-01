// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice FillGridStepwiseAdjusterBalanceIn opcode, taker stepwise discount based on fill percent grid
///   Applies last possible discount, no matching step means no discount
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * steps.length]
/// @dev Placement before or after InvalidateTokenOut selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional discounts should be applied after this opcode
library FillGridStepwiseAdjusterBalanceIn {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridStepwiseAdjusterNoPoints();
    error FillGridStepwiseAdjusterMismatchInputLengths();
    error FillGridStepwiseAdjusterBpsOutOfRange();
    error FillGridStepwiseAdjusterContextOverflow();

    Opcode constant opcode = Opcode.FillGridStepwiseAdjusterBalanceIn;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridStepwiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridStepwiseAdjusterNoPoints());

        ptr = ptrStart.pushHeader(opcode);
        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] <= BPS && adjustBps[i] <= BPS, FillGridStepwiseAdjusterBpsOutOfRange());
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

        uint24 fillBps;
        uint24 adjustBps;
        unchecked { (fillBps, adjustBps) = parsePoint(args, --count); }

        uint256 surcharge;
        uint256 discount;

        unchecked {
            if (ctx.query.isExactIn) {
                require(
                    ctx.swap.surcharge <= ctx.swap.balanceIn && ctx.swap.balanceIn <= type(uint232).max,
                    FillGridStepwiseAdjusterContextOverflow()
                );

                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;

                while (count > 0 && ctx.swap.amountIn < (ctx.swap.balanceIn - discount) * fillBps / BPS) {
                    (fillBps, adjustBps) = parsePoint(args, --count);
                    surcharge = ctx.swap.surcharge * adjustBps / BPS;
                    discount = ctx.swap.surcharge - surcharge;
                }

                if (ctx.swap.amountIn < (ctx.swap.balanceIn - discount) * fillBps / BPS) return;
            } else {
                require(
                    ctx.swap.surcharge <= type(uint232).max && ctx.swap.balanceOut <= type(uint232).max,
                    FillGridStepwiseAdjusterContextOverflow()
                );

                while (count > 0 && ctx.swap.amountOut < ctx.swap.balanceOut * fillBps / BPS) {
                    (fillBps, adjustBps) = parsePoint(args, --count);
                }

                if (ctx.swap.amountOut < ctx.swap.balanceOut * fillBps / BPS) return;

                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;
            }
        }

        ctx.swap.surcharge = surcharge;
        ctx.swap.balanceIn -= discount;
    }
}

/// @notice FillGridStepwiseAdjusterBalanceOut opcode, taker stepwise discount based on fill percent grid
///   Applies last possible discount, no matching step means no discount
/// @dev Encoding: [[uint24 fillBps, uint24 adjustBps] * steps.length]
/// @dev Placement before or after InvalidateTokenIn selects total-volume or remaining-volume eligibility
/// @dev Relies on the surcharge being final; no additional discounts should be applied after this opcode
library FillGridStepwiseAdjusterBalanceOut {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error FillGridStepwiseAdjusterNoPoints();
    error FillGridStepwiseAdjusterMismatchInputLengths();
    error FillGridStepwiseAdjusterBpsOutOfRange();
    error FillGridStepwiseAdjusterContextOverflow();

    Opcode constant opcode = Opcode.FillGridStepwiseAdjusterBalanceOut;

    uint256 constant BPS = 1e7;

    function sizeOf(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + fillBps.length * 3 + adjustBps.length * 3;
    }

    function build(uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(fillBps, adjustBps)), fillBps, adjustBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint24[] memory fillBps, uint24[] memory adjustBps) internal pure returns (MemoryPtr ptr) {
        require(fillBps.length == adjustBps.length, FillGridStepwiseAdjusterMismatchInputLengths());
        require(fillBps.length > 0, FillGridStepwiseAdjusterNoPoints());

        ptr = ptrStart.pushHeader(opcode);
        for (uint256 i; i < fillBps.length; i++) {
            require(fillBps[i] <= BPS && adjustBps[i] <= BPS, FillGridStepwiseAdjusterBpsOutOfRange());
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

        uint24 fillBps;
        uint24 adjustBps;
        unchecked { (fillBps, adjustBps) = parsePoint(args, --count); }

        uint256 surcharge;
        uint256 discount;

        unchecked {
            if (ctx.query.isExactIn) {
                require(
                    ctx.swap.surcharge <= type(uint232).max && ctx.swap.balanceIn <= type(uint232).max,
                    FillGridStepwiseAdjusterContextOverflow()
                );

                while (count > 0 && ctx.swap.amountIn < ctx.swap.balanceIn * fillBps / BPS) {
                    (fillBps, adjustBps) = parsePoint(args, --count);
                }

                if (ctx.swap.amountIn < ctx.swap.balanceIn * fillBps / BPS) return;

                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;
            } else {
                require(
                    ctx.swap.surcharge + ctx.swap.balanceOut >= ctx.swap.surcharge
                        && ctx.swap.surcharge + ctx.swap.balanceOut <= type(uint232).max,
                    FillGridStepwiseAdjusterContextOverflow()
                );

                surcharge = ctx.swap.surcharge * adjustBps / BPS;
                discount = ctx.swap.surcharge - surcharge;

                while (count > 0 && ctx.swap.amountOut < (ctx.swap.balanceOut + discount) * fillBps / BPS) {
                    (fillBps, adjustBps) = parsePoint(args, --count);
                    surcharge = ctx.swap.surcharge * adjustBps / BPS;
                    discount = ctx.swap.surcharge - surcharge;
                }

                if (ctx.swap.amountOut < (ctx.swap.balanceOut + discount) * fillBps / BPS) return;
            }
        }

        ctx.swap.balanceOut += discount;
        ctx.swap.surcharge = surcharge;
    }
}
