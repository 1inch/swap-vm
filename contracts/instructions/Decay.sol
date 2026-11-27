// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice Decay prevents the reverse-swap price from updating immediately
///   It spreads the swap amount over `period`, releasing liquidity to market over time
/// @dev Encoding: [uint16 period]
/// @dev Example: right after A → B swap, a B → A swap price does not change
///   Decay stores the swapped amounts and adjusts virtual balances to restore the price from before that A → B swap
///   This decreases arbitrage opportunity and complicates sandwich attacks
/// @dev Expected to run no more than once per strategy, the first instance writes storage
/// @dev The next same-direction swap within `period` adds the swap amounts to the remaining resistance prolonging its decaying
///   Do not overstate decay period to days or hours, keep it in range of dozens of blocks
library Decay {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    error DecayPeriodMustBeNonZero();

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2;
    }

    function build(uint16 period) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), period).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 period) internal pure returns (MemoryPtr ptr) {
        require(period > 0, DecayPeriodMustBeNonZero());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(period, 2);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    struct OrderResistance {
        Resistance direct;
        Resistance reverse;
    }

    struct Storage {
        mapping(bytes32 orderHash => OrderResistance) resistance;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        OrderResistance storage r = $.resistance[ctx.query.orderHash];
        bool direction = ctx.query.tokenIn < ctx.query.tokenOut;

        (uint256 retainedIn, uint256 retainedOut) = direction ? r.direct.remaining(period) : r.reverse.remaining(period);
        (uint256 resistanceIn, uint256 resistanceOut) = direction ? r.reverse.remaining(period) : r.direct.remaining(period);

        // Apply the remaining resistance before pricing
        ctx.swap.balanceIn += resistanceOut;
        ctx.swap.balanceOut -= resistanceIn;

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        Resistance retained = ResistanceLib.encodeNow(
            (retainedIn + amountIn).toUint112(),
            (retainedOut + amountOut).toUint112()
        );

        if (!ctx.vm.isStaticContext) {
            if (direction) r.direct = retained;
            else r.reverse = retained;
        }
    }
}

/// @dev External `Decay` getters
contract DecayExternal {
    /// @dev Unpacked representation of Resistance
    struct UnpackedResistance {
        uint112 amountIn;
        uint112 amountOut;
        uint32 timestamp;
    }

    /// @dev Remaining resistance applied crosswise to virtual balances:
    ///   `amountOut` increases `balanceIn`, while `amountIn` decreases `balanceOut`
    struct RemainingResistance {
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @dev Returns the resistance stored for an order
    /// @return direct Resistance accumulated by A → B swaps and applied to B → A swaps
    /// @return reverse Resistance accumulated by B → A swaps and applied to A → B swaps
    function decay(bytes32 orderHash) external view returns (
        UnpackedResistance memory direct, UnpackedResistance memory reverse
    ) {
        Decay.OrderResistance storage resistance = Decay.store().resistance[orderHash];

        (direct.amountIn, direct.amountOut, direct.timestamp) = resistance.direct.decode();
        (reverse.amountIn, reverse.amountOut, reverse.timestamp) = resistance.reverse.decode();
    }

    /// @dev Returns the resistance remaining at the current timestamp, using `period` as the total decay duration
    /// @return direct Remaining resistance accumulated by A → B swaps and applied to B → A swaps.
    /// @return reverse Remaining resistance accumulated by B → A swaps and applied to A → B swaps.
    function decayRemaining(bytes32 orderHash, uint16 period) external view returns (
        RemainingResistance memory direct, RemainingResistance memory reverse
    ) {
        Decay.OrderResistance storage resistance = Decay.store().resistance[orderHash];
        (direct.amountIn, direct.amountOut) = resistance.direct.remaining(period);
        (reverse.amountIn, reverse.amountOut) = resistance.reverse.remaining(period);
    }

    /// @dev Returns the resistance remaining at a timestamp, using `period` as the total decay duration
    ///   The result is valid only when `timestamp >= block.timestamp`
    /// @return direct Remaining resistance accumulated by A → B swaps and applied to B → A swaps
    /// @return reverse Remaining resistance accumulated by B → A swaps and applied to A → B swaps
    function decayRemainingAt(bytes32 orderHash, uint16 period, uint256 timestamp) external view returns (
        RemainingResistance memory direct, RemainingResistance memory reverse
    ) {
        Decay.OrderResistance storage resistance = Decay.store().resistance[orderHash];
        (direct.amountIn, direct.amountOut) = resistance.direct.remainingAt(period, timestamp);
        (reverse.amountIn, reverse.amountOut) = resistance.reverse.remainingAt(period, timestamp);
    }
}

/// @dev Packed resistance created by one swap direction
/// @dev Encoding: [uint112 amountIn, uint112 amountOut, uint32 ts]
///   The opposite direction adds `amountOut` to its virtual input balance and subtracts
///   `amountIn` from its virtual output balance. Both amounts decay linearly from `ts`
type Resistance is uint256;
using ResistanceLib for Resistance;

library ResistanceLib {
    function encodeNow(uint112 amountIn, uint112 amountOut) internal view returns (Resistance) {
        return Resistance.wrap((uint256(amountIn) << 144) | uint256(amountOut) << 32 | block.timestamp);
    }

    function decode(Resistance data) internal pure returns (uint112, uint112, uint32) {
        uint256 raw = Resistance.unwrap(data);
        return (uint112(raw >> 144), uint112(raw >> 32), uint32(raw));
    }

    function remaining(Resistance self, uint16 period) internal view returns(uint256 amountIn, uint256 amountOut) {
        unchecked {
            uint32 ts;
            (amountIn, amountOut, ts) = self.decode();

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return (0, 0);

            uint256 timeLeft = expiration - block.timestamp;
            amountIn = amountIn * timeLeft / period;
            amountOut = amountOut * timeLeft / period;
        }
    }

    // gas-savings (~80 gas): allow compiler to inline both `remaining` and `remainingAt`
    function remainingAt(Resistance self, uint16 period, uint256 timestamp) internal pure returns(uint256 amountIn, uint256 amountOut) {
        unchecked {
            uint32 ts;
            (amountIn, amountOut, ts) = self.decode();

            uint256 expiration = uint256(ts) + period;
            if (timestamp >= expiration) return (0, 0);

            uint256 timeLeft = expiration - timestamp;
            amountIn = amountIn * timeLeft / period;
            amountOut = amountOut * timeLeft / period;
        }
    }
}
