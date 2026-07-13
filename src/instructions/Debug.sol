// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { Context, SwapRegisters } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice PrintSwapRegisters opcode, print internal vm state for debugging
/// @dev Encoding: []
library PrintSwapRegisters {
    Opcode constant opcode = Opcode.PrintSwapRegisters;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        console.log("ctx.swap => SwapRegisters {");
        console.log("    balanceIn:      ", ctx.swap.balanceIn);
        console.log("    balanceOut:     ", ctx.swap.balanceOut);
        console.log("    amountIn:       ", ctx.swap.amountIn);
        console.log("    amountOut:      ", ctx.swap.amountOut);
        console.log("    amountNetPulled:", ctx.swap.amountNetPulled);
        console.log("}");
    }
}

/// @notice PrintSwapQuery opcode, print internal vm state for debugging
/// @dev Encoding: []
library PrintSwapQuery {
    Opcode constant opcode = Opcode.PrintSwapQuery;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
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

    Opcode constant opcode = Opcode.PrintVM;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        console.log("Context {");
        console.log("    vm.isStaticContext:", ctx.vm.isStaticContext);
        console.log("    vm.nextPC:         ", ctx.vm.nextPC);
        console.log("    vm.program:        ", toHexString(ctx.vm.programPtr.toBytes()));
        console.log("    vm.takerArgs:      ", toHexString(ctx.vm.takerArgsPtr.toBytes()));
        console.log("}");
    }
}

/// @notice PrintFreeMemoryPointer opcode, print internal execution details for debugging
/// @dev Encoding: []
library PrintFreeMemoryPointer {
    Opcode constant opcode = Opcode.PrintFreeMemoryPointer;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
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
    Opcode constant opcode = Opcode.PrintGasLeft;

    function build() internal pure returns (bytes memory) {
        return InstructionBuilder.build(opcode);
    }

    function exec(Context memory, bytes calldata) internal view {
        console.log("Gas left:", gasleft());
    }
}

/// @notice PatchSwapRegisters opcode, modify internal vm state for debugging
/// @dev Encoding: [SwapRegisters swap]
library PatchSwapRegisters {
    Opcode constant opcode = Opcode.PatchSwapRegisters;

    function build(SwapRegisters memory swap) internal pure returns (bytes memory) {
        bytes memory args = abi.encode(swap);
        return InstructionBuilder.build(opcode, args);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        ctx.swap = abi.decode(args, (SwapRegisters));
    }
}

function toHexString(bytes32 data) pure returns (string memory) {
    return Strings.toHexString(uint256(data));
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
