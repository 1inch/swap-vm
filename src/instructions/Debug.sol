// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { console } from "forge-std/console.sol";

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { Context, ContextLib } from "../libs/VM.sol";

contract Debug {
    using CalldataPtrLib for CalldataPtr;
    using ContextLib for Context;

    function _injectDebugOpcodes(function(Context memory, bytes calldata) internal[] memory opcodes) internal pure returns (function(Context memory, bytes calldata) internal[] memory) {
        opcodes[0] = Debug._printSwapRegisters;
        opcodes[1] = Debug._printSwapQuery;
        opcodes[2] = Debug._printContext;
        opcodes[3] = Debug._printFreeMemoryPointer;
        opcodes[4] = Debug._printGasLeft;
        return opcodes;
    }

    function _printSwapRegisters(Context memory ctx, bytes calldata /* args */) internal pure {
        console.log("ctx.swap => SwapRegisters {");
        console.log("    balanceIn:  ", ctx.swap.balanceIn, ",");
        console.log("    balanceOut: ", ctx.swap.balanceOut, ",");
        console.log("    amountIn:   ", ctx.swap.amountIn, ",");
        console.log("    amountOut:  ", ctx.swap.amountOut);
        console.log("}");
    }

    function _printSwapQuery(Context memory ctx, bytes calldata /* args */) internal pure {
        console.log("ctx.query => SwapQuery {");
        console.log("    orderHash:       ", Strings.toHexString(uint256(ctx.query.orderHash)), ",");
        console.log("    taker:           ", ctx.query.taker, ",");
        console.log("    maker:           ", ctx.query.maker, ",");
        console.log("    tokenIn:         ", ctx.query.tokenIn, ",");
        console.log("    tokenOut:        ", ctx.query.tokenOut, ",");
        console.log("    isExactIn:       ", ctx.query.isExactIn ? "true" : "false", ",");
        console.log("}");
    }

    function _printContext(Context memory ctx, bytes calldata /* args */) internal pure {
        console.log("Context {");
        console.log("    vm.nextPC:    ", ctx.vm.nextPC);
        console.log("    vm.takerArgs: ", _toHexString(ctx.vm.takerArgsPtr.toBytes()));
        console.log("}");
    }

    function _printGasLeft(Context memory /* ctx */, bytes calldata /* args */) internal view {
        console.log("Gas left:", gasleft());
    }

    function _printFreeMemoryPointer(Context memory /* ctx */, bytes calldata /* args */) internal pure {
        uint256 ptr;
        assembly ("memory-safe") {
            ptr := mload(0x40)
        }
        console.log("Free memory pointer:", ptr);
    }

    function _toHexString(bytes calldata data) private pure returns (string memory) {
        unchecked {
            bytes16 digits = "0123456789abcdef";
            bytes memory buffer = new bytes(2 + data.length * 2);
            buffer[0] = "0";
            buffer[1] = "x";
            for (uint256 i = 0; i < data.length; i++) {
                buffer[2 + i * 2] = digits[uint8(data[i] >> 4)];
                buffer[2 + i * 2 + 1] = digits[uint8(data[i] & 0x0f)];
            }
            return string(buffer);
        }
    }
}
