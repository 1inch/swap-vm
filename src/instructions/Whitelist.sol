// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice PrivateOrder opcode, allows the order to be executed only by the specified taker
/// @dev Encoding: [uint80 allowedTaker]
/// @dev Address packing trade-off: only the last 10 bytes of each address are compared
///   Mining 80 bits of an address takes millions of GPU-years, still avoid "free money" orders for long-known accounts
///   Birthday attack 80-bit collisions are feasible, however both accounts are controlled by a single attacker, not a bypass
library PrivateOrder {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error PrivateOrderInvalidTaker();

    Opcode constant opcode = Opcode.PrivateOrder;

    function sizeOf(address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 10;
    }

    function build(address allowedTaker) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(allowedTaker)), allowedTaker).resolve();
    }

    function build(MemoryPtr ptrStart, address allowedTaker) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(uint80(uint160(allowedTaker)), 10);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint80 allowedTaker) {
        allowedTaker = args.at(0).asU80();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint80 sender = uint80(uint160(ctx.query.taker));
        require(sender == parse(args), PrivateOrderInvalidTaker());
    }
}

/// @notice WhitelistCoequal opcode, jumps to the specified program counter if the taker is whitelisted,
///   continues execution normally otherwise
/// @dev Encoding: [uint16 nextPC, uint80 allowedTakers[N]]
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Address packing trade-off: only the last 10 bytes of each address are compared
///   Mining 80 bits of an address takes millions of GPU-years, still avoid "free money" orders for long-known accounts
///   Birthday attack 80-bit collisions are feasible, however both accounts are controlled by a single attacker, not a bypass
library WhitelistCoequal {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error WhitelistCoequalEmptyList();

    Opcode constant opcode = Opcode.WhitelistCoequal;

    function sizeOf(uint16, address[] memory allowedTakers) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2 + allowedTakers.length * 10;
    }

    function build(uint16 nextPC, address[] memory allowedTakers) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(nextPC, allowedTakers)), nextPC, allowedTakers).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 nextPC, address[] memory allowedTakers) internal pure returns (MemoryPtr ptr) {
        require(allowedTakers.length > 0, WhitelistCoequalEmptyList());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(nextPC, 2);
        for (uint256 i; i < allowedTakers.length; i++) {
            ptr = ptr.push(uint80(uint160(allowedTakers[i])), 10);
        }
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionBuilder.sizeOf()).patch(nextPC, 2);
    }

    function parseNextPC(bytes calldata args) internal pure returns (uint16 nextPC) {
        nextPC = args.at(0).asU16();
    }

    function parseTaker(bytes calldata args, uint256 i) internal pure returns (uint80 allowedTaker) {
        unchecked { allowedTaker = args.at(2 + i * 10).asU80(); }
    }

    function parseTakersCount(bytes calldata args) internal pure returns (uint256 count) {
        unchecked { count = (args.length - 2) / 10; }
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint80 sender = uint80(uint160(ctx.query.taker));

        uint256 count = parseTakersCount(args);
        for (uint256 i; i < count; i++) {
            if (sender == parseTaker(args, i)) {
                ctx.setNextPC(parseNextPC(args));
                return;
            }
        }
    }
}

/// @notice WhitelistSequential opcode, time-phased whitelist unlocking takers one by one, jumps to the specified program counter if
///   the taker is whitelisted and unlocked, continues execution normally once whitelist-exclusive period has passed, reverts otherwise
/// @dev Encoding: [uint40 start, uint16 nextPC, (uint16 duration, uint80 allowedTaker)[N]]
///   The whitelist is empty before `start`, the k-th taker unlocks at `start + sum(durations[0:k])`
///   `nextPC` is expected to be a valid, instruction-aligned offset in `program`
/// @dev Address packing trade-off: only the last 10 bytes of each address are compared
///   Mining 80 bits of an address takes millions of GPU-years, still avoid "free money" orders for long-known accounts
///   Birthday attack 80-bit collisions are feasible, however both accounts are controlled by a single attacker, not a bypass
library WhitelistSequential {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    error WhitelistSequentialEmptyList();
    error WhitelistSequentialLengthMismatch();
    error WhitelistSequentialTimeViolation();

    Opcode constant opcode = Opcode.WhitelistSequential;

    function sizeOf(uint40, uint16, address[] memory allowedTakers, uint16[] memory durations) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 5 + 2 + durations.length * 2 + allowedTakers.length * 10;
    }

    function build(
        uint40 start,
        uint16 nextPC,
        address[] memory allowedTakers,
        uint16[] memory durations
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(start, nextPC, allowedTakers, durations)),
            start, nextPC, allowedTakers, durations
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint40 start,
        uint16 nextPC,
        address[] memory allowedTakers,
        uint16[] memory durations
    ) internal pure returns (MemoryPtr ptr) {
        require(allowedTakers.length > 0, WhitelistSequentialEmptyList());
        require(allowedTakers.length == durations.length, WhitelistSequentialLengthMismatch());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(start, 5).push(nextPC, 2);
        for (uint256 i; i < allowedTakers.length; i++) {
            ptr = ptr.push(durations[i], 2).push(uint80(uint160(allowedTakers[i])), 10);
        }
        ptrStart.patchLength(ptr);
    }

    function patchNextPC(MemoryPtr ptrStart, uint16 nextPC) internal pure {
        ptrStart.skip(InstructionBuilder.sizeOf() + 5).patch(nextPC, 2);
    }

    function parseStart(bytes calldata args) internal pure returns (uint40 start) {
        start = args.at(0).asU40();
    }

    function parseNextPC(bytes calldata args) internal pure returns (uint16 nextPC) {
        nextPC = args.at(5).asU16();
    }

    function parseTaker(bytes calldata args, uint256 n) internal pure returns (uint16 duration, uint80 allowedTaker) {
        unchecked {
            // Skip [start, nextPC, n * [duration[k], allowedTaker[k]]]
            uint256 shift = (5 + 2) + n * 12;
            duration = args.at(shift).asU16();
            allowedTaker = args.at(shift + 2).asU80();
        }
    }

    function parseTakersCount(bytes calldata args) internal pure returns (uint256 count) {
        // Skip [start, nextPC], divide by [duration, allowedTaker] length
        unchecked { count = (args.length - (5 + 2)) / 12; }
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        uint80 sender = uint80(uint160(ctx.query.taker));

        uint256 timeLeft = block.timestamp;
        uint40 start = parseStart(args);
        require(timeLeft >= start, WhitelistSequentialTimeViolation());
        unchecked { timeLeft -= start; }

        uint256 count = parseTakersCount(args);
        for (uint256 i; i < count; i++) {
            (uint16 duration, uint80 allowedTaker) = parseTaker(args, i);

            if (sender == allowedTaker) {
                ctx.setNextPC(parseNextPC(args));
                return;
            }

            require(timeLeft >= duration, WhitelistSequentialTimeViolation());
            unchecked { timeLeft -= duration; }
        }
    }
}
