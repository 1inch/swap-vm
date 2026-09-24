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
///  It spreads the swap amount over `period`, which shrinks the arbitrage window.
///
/// @dev Example: after A → B, a B → A swap is filled at a worse price.
///  Decay stores the swapped amounts and adjusts virtual balances to restore
///  the price from before that A → B, not the price at which A → B filled.
///  This can defend against front-running and sandwich attacks.
///
/// @dev Encoding: [uint16 period]
/// @dev Expected to run once per strategy; the first instance writes storage.
library Decay {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    error PeriodMustBeNonZero();

    function sizeOf(uint16) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2;
    }

    function build(uint16 period) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(period)), period).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 period) internal pure returns (MemoryPtr ptr) {
        require(period > 0, PeriodMustBeNonZero());
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(period, 2);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    /// @dev One packed slot per swap direction.
    struct OrderResistance {
        Resistance aToB;
        Resistance bToA;
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

        OrderResistance storage r = $.orderResistance[ctx.query.orderHash];
        bool aToB = ctx.query.tokenIn < ctx.query.tokenOut;

        (uint112 forwardIn, uint112 forwardOut) = aToB ? r.aToB.remaining(period) : r.bToA.remaining(period);
        (uint112 backwardIn, uint112 backwardOut) = aToB ? r.bToA.remaining(period) : r.aToB.remaining(period);

        // Apply the remaining resistance before pricing.
        ctx.swap.balanceIn += backwardOut;
        ctx.swap.balanceOut -= backwardIn;

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        // Update out of `if (!ctx.vm.isStaticContext) {}` because casting `toUint112()` can potentially revert.
        Resistance forwardUpdated = ResistanceLib.encode(
            forwardIn + amountIn.toUint112(),
            forwardOut + amountOut.toUint112(),
            uint32(block.timestamp)
        );

        if (!ctx.vm.isStaticContext) {
            if (aToB) r.aToB = forwardUpdated;
            else r.bToA = forwardUpdated;
        }
    }
}


/// @dev Packed resistance created by one swap direction:
///  `uint112 amountIn | uint112 amountOut | uint32 ts`.
///  The opposite direction adds `amountOut` to its virtual input balance and subtracts
///  `amountIn` from its virtual output balance. Both amounts decay linearly from `ts`.
type Resistance is uint256;
using ResistanceLib for Resistance;

library ResistanceLib {
    function encode(uint112 amountIn, uint112 amountOut, uint32 ts) internal pure returns (Resistance) {
        return Resistance.wrap((uint256(amountIn) << 144) | uint256(amountOut) << 32 | ts);
    }

    function decode(Resistance data) internal pure returns (uint112, uint112, uint32) {
        uint256 raw = Resistance.unwrap(data);
        return (uint112(raw >> 144), uint112(raw >> 32), uint32(raw));
    }

    function remaining(Resistance self, uint16 period) internal view returns(uint112 amountIn, uint112 amountOut) {
        uint32 ts;
        (amountIn, amountOut, ts) = self.decode();

        uint256 expiration = uint256(ts) + period;
        if (block.timestamp >= expiration) return (0, 0);

        uint256 timeLeft = expiration - block.timestamp;
        amountIn = uint112(uint256(amountIn) * timeLeft / period);
        amountOut = uint112(uint256(amountOut) * timeLeft / period);
    }
}