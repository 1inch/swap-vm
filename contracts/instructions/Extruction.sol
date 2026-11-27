// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { CalldataCut } from "@1inch/solidity-utils/contracts/libraries/CalldataCut.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context, SwapRegisters, SwapQuery } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { IExtruction } from "./interfaces/IExtruction.sol";

/// @notice Extruction opcode, delegates swap registers to an external maker-chosen contract
///   The target may modify the swap registers, set the program counter and consume taker args
/// @dev Encoding: [address target, bytes extructionArgs]
/// @dev The extruction target is expected to be deterministic, consistent across quote / swap modes, calculations are
///   expected to be overflow-safe, revert conditions should be transparent, centralization and upgradability avoided
/// @dev General safety measures:
///   Maker min exchange rate expectations should be guarded by using RequireMinRate before Extruction
///   Maker max spend expectations should be guarded by using AQUA or DynamicBalances for AMM-strategies
///   or using StaticBalances with InvalidateTokenIn or InvalidateTokenOut before Extruction for amount-limited strategies
///
///   Taker should employ threshold to guard the min exchange rate
///   SwapVM guards taker-specified amount to be unchanged by the strategy execution
/// @dev Execution of the opcode multiple times in strategy flow may lead to quote / swap divergence:
///   In swap mode extruction target may update storage affecting future executions while in quote mode storage could be only read
library Extruction {
    using CalldataCut for bytes;
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    error ExtructionChoppedExceedsLength(uint256 chopped, uint256 requested);

    Opcode constant opcode = Opcode.Extruction;

    function sizeOf(uint256 extructionArgsLen) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + extructionArgsLen;
    }

    function build(address target, bytes memory extructionArgs) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(extructionArgs.length)), target, extructionArgs).resolve();
    }

    function build(MemoryPtr ptrStart, address target, bytes memory extructionArgs) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(target).pushMem(extructionArgs);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (address target, bytes calldata extructionArgs) {
        target = args.at(0).asAddress();
        extructionArgs = args.slice(20);
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (address target, bytes calldata extructionArgs) = parse(args);

        uint256 choppedLength;
        bytes4 selector = IExtruction.extruction.selector;

        uint256 pcs = ctx.vm.nextPC;
        bool isStatic = ctx.vm.isStaticContext;
        SwapQuery memory query = ctx.query;
        SwapRegisters memory swap = ctx.swap;
        bytes calldata takerArgs = ctx.takerArgs();

        assembly ("memory-safe") {
            let extructionArgsAligned := mul(div(add(extructionArgs.length, 31), 32), 32)
            let takerArgsAligned := mul(div(add(takerArgs.length, 31), 32), 32)

            let ptr := mload(0x40)
            let length := add(0x0224, add(extructionArgsAligned, takerArgsAligned))
            calldatacopy(ptr, calldatasize(), length) // cleanup

            // Static encoding 0x01a4 bytes
            mstore(ptr, selector)               // selector
            mstore(add(ptr, 0x04), isStatic)    // ctx.vm.isStaticContext
            mstore(add(ptr, 0x24), pcs)         // ctx.vm.nextPC
            mcopy(add(ptr, 0x44), query, 0xc0)  // ctx.query
            mcopy(add(ptr, 0x0104), swap, 0xa0) // ctx.swap

            // Dynamic part offsets 0x40 bytes
            mstore(add(ptr, 0x01a4), 0x01e0)                             // extructionArgs offset
            mstore(add(ptr, 0x01c4), add(0x0200, extructionArgsAligned)) // takerArgs offset

            // Dynamic encoding 32 + extructionArgsAligned + 32 + takerArgsAligned bytes
            mstore(add(ptr, 0x01e4), extructionArgs.length)                                                // extructionArgs.length
            calldatacopy(add(ptr, 0x0204), extructionArgs.offset, extructionArgs.length)                   // extructionArgs
            mstore(add(add(ptr, 0x0204), extructionArgsAligned), takerArgs.length)                         // takerArgs.length
            calldatacopy(add(add(ptr, 0x0224), extructionArgsAligned), takerArgs.offset, takerArgs.length) // takerArgs

            let ok := 0
            switch isStatic
            case 0 { ok := call(gas(), target, 0, ptr, length, ptr, 64) }
            default { ok := staticcall(gas(), target, ptr, length, ptr, 64) }

            if or(iszero(ok), lt(returndatasize(), 224)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }

            pcs := mload(ptr)
            choppedLength := mload(add(ptr, 32))
            returndatacopy(swap, 64, 160)
        }

        ctx.vm.nextPC = pcs;
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength); // Consumed taker arguments
        require(chopped.length == choppedLength, ExtructionChoppedExceedsLength(chopped.length, choppedLength));
    }
}
