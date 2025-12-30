// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

/// @dev Represents the state of the VM
/// @param isStaticContext Whether the quote is in a static context (e.g., for quoting)
/// @param nextPC The program counter for the next instruction to execute
/// @param programPtr Pointer to the program in calldata (offset and length)
/// @param takerArgsPtr Pointer to the taker's data in calldata (offset and length)
/// @param opcodes The set of instructions (functions) that can be executed by the VM
/// @dev This struct is used to track the execution state of instructions during a swap
struct VM {
    bool isStaticContext;
    uint256 nextPC;
    CalldataPtr programPtr; // Use ContextLib.program()
    CalldataPtr takerArgsPtr; // Use ContextLib.takerArgs()
    function(Context memory, bytes calldata) internal[] opcodes;
}

/// @dev Represents the read-only swap information
/// @param orderHash The unique (per maker) position/strategy identifier for the swap position
/// @param maker The address of the maker (the one who provides liquidity)
/// @param taker The address of the taker (the one who performs the swap)
/// @param tokenIn The address of the input token
/// @param tokenOut The address of the output token
struct SwapQuery {
    bytes32 orderHash;
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    bool isExactIn;
}

/// @dev Registers used to compute missing amount: `isExactIn() ? amountOut : amountIn`
/// @param balanceIn The current balance of the input token
/// @param balanceOut The current balance of the output token
/// @param amountIn The amount of input token being swapped
/// @param amountOut The amount of output token being swapped
struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
}

/// @title SwapVM context
/// @dev This struct is used to represent the state of the VM during a swap operation
/// @param vm #readonly The state of the VM, including the program counter
/// @param query #readonly The read-only swap details
/// @param swap The registers used to compute missing amounts during the swap
struct Context {
    VM vm;
    SwapQuery query;
    SwapRegisters swap; // Registers used to compute missing amount (amountOut for isExactIn and amountIn for !isExactIn)
}

library ContextLib {
    using Calldata for bytes;
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    error TryChopTakerArgsExcessiveLength();
    error RunLoopExcessiveCall(uint256 pc, uint256 programLength);
    error RunLoopSwapAmountsComputationMissing(uint256 amountIn, uint256 amountOut);

    function program(Context memory ctx) internal pure returns (bytes calldata) {
        return ctx.vm.programPtr.toBytes();
    }

    function takerArgs(Context memory ctx) internal pure returns (bytes calldata) {
        return ctx.vm.takerArgsPtr.toBytes();
    }

    function setNextPC(Context memory ctx, uint256 pc) internal pure {
        ctx.vm.nextPC = pc;
    }

    function tryChopTakerArgs(Context memory ctx, uint256 length) internal pure returns (bytes calldata) {
        bytes calldata data = ctx.vm.takerArgsPtr.toBytes();
        length = Math.min(length, data.length);
        ctx.vm.takerArgsPtr = CalldataPtrLib.from(data.slice(length, TryChopTakerArgsExcessiveLength.selector));
        return data.slice(0, length);
    }

    function runLoop(Context memory ctx) internal returns (uint256 swapAmountIn, uint256 swapAmountOut) {
        bytes calldata programBytes = ctx.program();
        require(ctx.vm.nextPC < programBytes.length, RunLoopExcessiveCall(ctx.vm.nextPC, programBytes.length));

        for (uint256 pc = ctx.vm.nextPC; pc < programBytes.length; ) {
            unchecked {
                uint256 opcode = uint8(programBytes[pc++]);
                uint256 argsLength = uint8(programBytes[pc++]);
                uint256 nextPC = pc + argsLength;
                bytes calldata args = programBytes[pc:nextPC];

                ctx.vm.nextPC = nextPC;
                ctx.vm.opcodes[opcode](ctx, args);
                pc = ctx.vm.nextPC;
            }
        }

        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }
}
