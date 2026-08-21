// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { Context, ContextLib, SwapRegisters } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { FeeMetaLib, FeeReceiverLib } from "../libs/ProtocolFee.sol";

/// @notice PrintSwapRegisters opcode, print internal vm state for debugging
/// @dev Encoding: []
library PrintSwapRegisters {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PrintSwapRegisters;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        console.log("ctx.swap => SwapRegisters {");
        console.log("    balanceIn: ", ctx.swap.balanceIn);
        console.log("    balanceOut:", ctx.swap.balanceOut);
        console.log("    amountIn:  ", ctx.swap.amountIn);
        console.log("    amountOut: ", ctx.swap.amountOut);
        console.log("}");
    }
}

/// @notice PrintSwapQuery opcode, print internal vm state for debugging
/// @dev Encoding: []
library PrintSwapQuery {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PrintSwapQuery;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        console.log("ctx.query => SwapQuery {");
        console.log("    orderHash:", toHexString(ctx.query.orderHash));
        console.log("    maker:    ", ctx.query.maker);
        console.log("    taker:    ", ctx.query.taker);
        console.log("    tokenIn:  ", ctx.query.tokenIn);
        console.log("    tokenOut: ", ctx.query.tokenOut);
        console.log("    isExactIn:", ctx.query.isExactIn);
        console.log("}");
    }
}

/// @notice PrintVM opcode, print internal vm state for debugging
/// @dev Encoding: []
library PrintVM {
    using CalldataPtrLib for CalldataPtr;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PrintVM;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        console.log("Context {");
        console.log("    isStaticContext:", ctx.vm.isStaticContext);
        console.log("    nextPC:         ", ctx.vm.nextPC);
        console.log("    program:        ", toHexString(ctx.vm.programPtr.toBytes()));
        console.log("    takerArgs:      ", toHexString(ctx.vm.takerArgsPtr.toBytes()));
        console.log("}");
    }
}

/// @notice PrintFee opcode, print internal vm state for debugging
/// @dev Encoding: []
/// @dev FeeProtocol opcode updates registries after strategy execution
///   The PrintFee opcode should be included before FeeProtocol to trigger delayed registries print
library PrintFee {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using ContextLib for Context;

    Opcode constant opcode = Opcode.PrintFee;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal {
        ctx.runLoop();

        uint8 count = FeeMetaLib.decodeCount(ctx.fee.meta);

        console.log("ProtocolFee {");
        console.log("    count:    ", count);
        console.log("    isTokenIn:", FeeMetaLib.decodeIsTokenIn(ctx.fee.meta));
        console.log("    totalBps: ", FeeMetaLib.decodeTotalBps(ctx.fee.meta));
        console.log("    estimated:", FeeMetaLib.decodeSurplusEstimate(ctx.fee.meta));
        for (uint256 i; i < count; i++) {
            console.log(string.concat("    receiver[", toHexString(i), "]:  "), FeeReceiverLib.decodeReceiver(ctx.fee.receivers[i]));
            console.log(string.concat("    feeBps[", toHexString(i), "]:    "), FeeReceiverLib.decodeFeeBps(ctx.fee.receivers[i]));
            console.log(string.concat("    surplusBps[", toHexString(i), "]:"), FeeReceiverLib.decodeSurplusBps(ctx.fee.receivers[i]));
        }
        console.log("}");
    }
}

/// @notice PrintFreeMemoryPointer opcode, print internal execution details for debugging
/// @dev Encoding: []
library PrintFreeMemoryPointer {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PrintFreeMemoryPointer;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata) internal pure {
        uint256 ptr;
        assembly ("memory-safe") { ptr := mload(0x40) }
        console.log("Free memory pointer:", ptr);
    }
}

/// @notice PrintGasLeft opcode, print internal execution details for debugging
/// @dev Encoding: []
library PrintGasLeft {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PrintGasLeft;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory, bytes calldata) internal view {
        console.log("Gas left:", gasleft());
    }
}

/// @notice PatchSwapRegisters opcode, modify internal vm state for debugging
/// @dev Encoding: [uint256 balanceIn, uint256 balanceOut, uint256 amountIn, uint256 amountOut]
library PatchSwapRegisters {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.PatchSwapRegisters;

    function sizeOf(SwapRegisters memory) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 32 + 32 + 32 + 32;
    }

    function build(SwapRegisters memory swap) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(swap)), swap).resolve();
    }

    function build(MemoryPtr ptrStart, SwapRegisters memory swap) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(swap.balanceIn, 32).push(swap.balanceOut, 32).push(swap.amountIn, 32).push(swap.amountOut, 32);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (SwapRegisters memory) {
        return SwapRegisters({
            balanceIn: args.at(0).asU256(),
            balanceOut: args.at(32).asU256(),
            amountIn: args.at(64).asU256(),
            amountOut: args.at(96).asU256()
        });
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        ctx.swap = parse(args);
    }
}

function toHexString(bytes32 data) pure returns (string memory) {
    return Strings.toHexString(uint256(data));
}

function toHexString(uint256 data) pure returns (string memory) {
    return Strings.toHexString(data);
}

function toHexString(bytes calldata data) pure returns (string memory) {
    unchecked {
        bytes16 digits = "0123456789abcdef";
        bytes memory buffer = new bytes(2 + data.length * 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i; i < data.length; i++) {
            buffer[2 + i * 2] = digits[uint8(data[i] >> 4)];
            buffer[2 + i * 2 + 1] = digits[uint8(data[i] & 0x0f)];
        }
        return string(buffer);
    }
}
