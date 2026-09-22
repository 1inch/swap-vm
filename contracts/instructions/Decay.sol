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

    /// @dev Token amounts that resist price changes on the following counter-swaps.
    ///
    ///      asInput:  this token left the pool the last time it was sold. On a buy of this
    ///                token, add that amount back (`balanceIn += remaining`).
    ///      asOutput: this token entered the pool the last time it was bought. On a sell of
    ///                this token, take that amount back out (`balanceOut -= remaining`).
    ///
    ///      A → B stores `A.asOutput = dx` and `B.asInput = dy`. The following B → A uses them
    ///      and gets the price from before that A → B.
    struct TokenResistance {
        /// @dev Remaining T that previously left the pool; added to balanceIn when T is tokenIn.
        Resistance asInput;
        /// @dev Remaining T that previously entered the pool; subtracted from balanceOut when T is tokenOut.
        Resistance asOutput;
    }

    /// @dev Both tokens of a two-sided order. `tokenA` is the smaller address.
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

        ctx.swap.balanceIn += remainingResistance(resistanceIn.asInput, period);
        ctx.swap.balanceOut -= remainingResistance(resistanceOut.asOutput, period); 

        uint216 remainingResistanceIn = remainingResistance(resistanceIn.asOutput, period);
        uint216 remainingResistanceOut = remainingResistance(resistanceOut.asInput, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            resistanceIn.asOutput = ResistanceLib.encode(remainingResistanceIn + amountIn.toUint216(), uint40(block.timestamp));
            resistanceOut.asInput = ResistanceLib.encode(remainingResistanceOut + amountOut.toUint216(), uint40(block.timestamp));
        }
    }

    /// @dev Virtual balance decreases linearly over time. Returns the remaining amount within the period.
    function remainingResistance(Resistance data, uint16 period) internal view returns (uint216) {
        unchecked {
            (uint216 amount, uint40 ts) = ResistanceLib.decode(data);

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return 0;
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return uint216(amount * timeLeft / period);
        }
    }
}

/// @dev Remaining amount of the token swapped in previous swaps and not yet expired.
type Resistance is uint256;

library ResistanceLib {
    function encode(uint216 amount, uint40 ts) internal pure returns (Resistance) {
        return Resistance.wrap((uint256(amount) << 40) | ts);
    }

    function decode(Resistance data) internal pure returns (uint216 amount, uint40 ts) {
        return (uint216(Resistance.unwrap(data) >> 40), uint40(Resistance.unwrap(data)));
    }
}