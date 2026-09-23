// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Decay prevents the reverse-swap price from updating immediately.
///     It spreads the swap amount over `period`, which shrinks the arbitrage window.
///
/// @dev Example: after A → B, a B → A swap is filled at a worse price.
///     Decay stores the swapped amounts and adjusts virtual balances to restore
///     the price from before that A → B, not the price at which A → B filled.
///     This can defend against front-running and sandwich attacks.
///
/// @dev Encoding: [uint16 period]
/// @dev Expected to run once per strategy; the first instance writes storage.
library Decay {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    function sizeOf(uint16) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2;
    }

    function build(uint16 period) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(period)), period).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 period) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(period, 2);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    /// @dev Two packed slots (`tokenA`, `tokenB`). `tokenA` is the smaller address.
    struct OrderResistance {
        Resistance tokenA;
        Resistance tokenB;
    }

    struct Storage {
        mapping(bytes32 orderHash => OrderResistance) orderResistance;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        OrderResistance storage resistance = $.orderResistance[ctx.query.orderHash];
        bool aToB = ctx.query.tokenIn < ctx.query.tokenOut;

        Resistance resistanceIn = aToB ? resistance.tokenA : resistance.tokenB;
        Resistance resistanceOut = aToB ? resistance.tokenB : resistance.tokenA;

        // Both slots are written with the same timestamp.
        (uint112 resistanceInAsInput, uint112 resistanceInAsOutput, uint32 ts) = resistanceIn.decode();
        (uint112 resistanceOutAsInput, uint112 resistanceOutAsOutput, ) = resistanceOut.decode();

        uint256 expiration = uint256(ts) + period;
        uint256 timeLeft = block.timestamp < expiration ? expiration - block.timestamp : 0;

        uint112 remainingInAsInput = remainingResistance(resistanceInAsInput, timeLeft, period);
        uint112 remainingOutAsOutput = remainingResistance(resistanceOutAsOutput, timeLeft, period);
        // Apply the remaining resistance before pricing.
        ctx.swap.balanceIn += remainingInAsInput;
        ctx.swap.balanceOut -= remainingOutAsOutput;

        uint112 remainingInAsOutput = remainingResistance(resistanceInAsOutput, timeLeft, period);
        uint112 remainingOutAsInput = remainingResistance(resistanceOutAsInput, timeLeft, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            // Carry leftovers forward and add this swap.
            uint32 current_ts = uint32(block.timestamp);
            Resistance resistanceInUpdated = ResistanceLib.encode(remainingInAsInput, remainingInAsOutput + amountIn.toUint112(), current_ts);
            Resistance resistanceOutUpdated = ResistanceLib.encode(remainingOutAsInput + amountOut.toUint112(),remainingOutAsOutput, current_ts);
            if (aToB) {
                resistance.tokenA = resistanceInUpdated;
                resistance.tokenB = resistanceOutUpdated;
            } else {
                resistance.tokenA = resistanceOutUpdated;
                resistance.tokenB = resistanceInUpdated;
            }
        }
    }

    function remainingResistance(uint112 amount, uint256 timeLeft, uint16 period) private pure returns (uint112) {
        if (timeLeft == 0) return 0;
        return uint112(uint256(amount) * timeLeft / period);
    }
}


/// @dev Packed per-token resistance: `uint112 asInput | uint112 asOutput | uint32 ts`.
///      `asInput` is the amount that left the pool when this token was sold; it is added
///      to `balanceIn` when this token is bought. `asOutput` is the amount that entered
///      the pool when this token was bought; it is subtracted from `balanceOut` when this
///      token is sold. Both amounts decay linearly from `ts` over the instruction period.
///      A → B stores `A.asOutput = amountIn` and `B.asInput = amountOut`.
type Resistance is uint256;
using ResistanceLib for Resistance;

library ResistanceLib {
    function encode(uint112 asInput, uint112 asOutput, uint32 ts) internal pure returns (Resistance) {
        return Resistance.wrap((uint256(asInput) << 144) | uint256(asOutput) << 32 | ts);
    }

    function decode(Resistance data) internal pure returns (uint112, uint112, uint32) {
        uint256 raw = Resistance.unwrap(data);
        return (uint112(raw >> 144), uint112(raw >> 32), uint32(raw));
    }
}