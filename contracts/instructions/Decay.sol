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

    /// @dev Per-token leftover, one storage slot: `uint112 asInput | uint112 asOutput | uint32 ts`.
    ///      Amounts fade linearly from `ts` over the instruction `period`. A swap that
    ///      exceeds `uint112` (or leftover + amount) reverts.
    ///
    ///      asInput:  this token left the pool the last time it was sold. On a buy of this
    ///                token, add that amount back (`balanceIn += remaining`).
    ///      asOutput: this token entered the pool the last time it was bought. On a sell of
    ///                this token, take that amount back out (`balanceOut -= remaining`).
    ///      ts:       last time this token's leftover was written.
    ///
    ///      A → B stores `A.asOutput = dx` and `B.asInput = dy`. The following B → A uses them
    ///      and gets the price from before that A → B.
    struct TokenResistance {
        /// @dev Leftover of T that left the pool; added to balanceIn when T is tokenIn.
        uint112 asInput;
        /// @dev Leftover of T that entered the pool; subtracted from balanceOut when T is tokenOut.
        uint112 asOutput;
        /// @dev Timestamp of the last write to this slot.
        uint32 ts;
    }

    /// @dev Two packed slots (`tokenA`, `tokenB`). `tokenA` is the smaller address.
    struct OrderResistance {
        TokenResistance tokenA;
        TokenResistance tokenB;
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

        TokenResistance storage resistanceIn = aToB ? resistance.tokenA : resistance.tokenB;
        TokenResistance storage resistanceOut = aToB ? resistance.tokenB : resistance.tokenA;

        uint112 remainingInAsInput = remainingResistance(resistanceIn.asInput, resistanceIn.ts, period);
        uint112 remainingOutAsOutput = remainingResistance(resistanceOut.asOutput, resistanceOut.ts, period);
        ctx.swap.balanceIn += remainingInAsInput;
        ctx.swap.balanceOut -= remainingOutAsOutput;

        uint112 remainingInAsOutput = remainingResistance(resistanceIn.asOutput, resistanceIn.ts, period);
        uint112 remainingOutAsInput = remainingResistance(resistanceOut.asInput, resistanceOut.ts, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            uint32 ts = uint32(block.timestamp);
            TokenResistance memory inUpdated = TokenResistance({
                asInput: remainingInAsInput,
                asOutput: remainingInAsOutput + amountIn.toUint112(),
                ts: ts
            });
            TokenResistance memory outUpdated = TokenResistance({
                asInput: remainingOutAsInput + amountOut.toUint112(),
                asOutput: remainingOutAsOutput,
                ts: ts
            });
            if (aToB) {
                resistance.tokenA = inUpdated;
                resistance.tokenB = outUpdated;
            } else {
                resistance.tokenB = inUpdated;
                resistance.tokenA = outUpdated;
            }
        }
    }

    /// @dev Leftover amount after linear decay from `ts` over `period`. Zero if expired.
    function remainingResistance(uint112 amount, uint32 ts, uint16 period) internal view returns (uint112) {
        unchecked {
            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return 0;
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return uint112(amount * timeLeft / period);
        }
    }
}
