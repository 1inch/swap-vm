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
/// @param dispatch Opcode dispatcher: maps an opcode index to its instruction handler and executes it
/// @dev This struct is used to track the execution state of instructions during a swap
struct VM {
    bool isStaticContext;
    uint256 nextPC;
    CalldataPtr programPtr; // Use ContextLib.program()
    CalldataPtr takerArgsPtr; // Use ContextLib.takerArgs()
    function(Context memory, uint256, bytes calldata) internal dispatch;
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
/// @param amountNetPulled The net amount pulled from the maker during the swap, used for fee calculations
struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 amountNetPulled;
}

/// @title SwapVM context
/// @notice Complete execution state for a swap operation
/// @param vm The VM execution state including program counter and bytecode
/// @param query Read-only swap information (maker, taker, tokens, etc.)
/// @param swap Mutable registers for computing swap amounts
struct Context {
    VM vm;
    SwapQuery query;
    SwapRegisters swap;
}

/// @title ContextLib
/// @notice Library for managing VM execution context and program execution
library ContextLib {
    using Calldata for bytes;
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    /// @dev Program counter overflows program length
    error RunLoopExceedProgramLength(uint256 pc, uint256 programLength);

    /// @notice Get the program bytecode from context
    /// @param ctx Execution context
    /// @return Program bytecode as calldata slice
    function program(Context memory ctx) internal pure returns (bytes calldata) {
        return ctx.vm.programPtr.toBytes();
    }

    /// @notice Get remaining taker arguments from context
    /// @param ctx Execution context
    /// @return Taker arguments as calldata slice
    function takerArgs(Context memory ctx) internal pure returns (bytes calldata) {
        return ctx.vm.takerArgsPtr.toBytes();
    }

    /// @notice Set the program counter to a specific position
    /// @param ctx Execution context
    /// @param pc New program counter value
    function setNextPC(Context memory ctx, uint256 pc) internal pure {
        ctx.vm.nextPC = pc;
    }

    /// @notice Consume and return taker arguments from the front
    /// @param ctx Execution context
    /// @param length Number of bytes to consume
    /// @return Consumed taker arguments (up to length bytes)
    function tryChopTakerArgs(Context memory ctx, uint256 length) internal pure returns (bytes calldata) {
        bytes calldata data = ctx.vm.takerArgsPtr.toBytes();
        length = Math.min(length, data.length);
        ctx.vm.takerArgsPtr = CalldataPtrLib.from(data.slice(length));
        return data.slice(0, length);
    }

    /// @notice Execute program instructions sequentially
    /// @dev Iterates through bytecode, executing each instruction until program end
    /// @param ctx Execution context containing program and registers
    /// @return swapAmountIn Final computed input amount
    /// @return swapAmountOut Final computed output amount
    function runLoop(Context memory ctx) internal returns (uint256 swapAmountIn, uint256 swapAmountOut) {
        bytes calldata programBytes = ctx.program();

        uint256 length = programBytes.length;
        uint256 pcs = ctx.vm.nextPC;
        while (pcs < length) {
            uint256 opcode;
            bytes calldata args;

            assembly ("memory-safe") {
                let word := calldataload(add(programBytes.offset, pcs))

                opcode := shr(248, word)
                let argsLength := and(shr(240, word), 0xff)

                pcs := add(pcs, 2)

                args.offset := add(programBytes.offset, pcs)
                args.length := argsLength

                pcs := add(pcs, argsLength)
            }

            // Program counter should not exceed program length
            // In case this happened, parsed args read out-of-bounds
            if (pcs > length) revert RunLoopExceedProgramLength(pcs, length);

            ctx.vm.nextPC = pcs;
            ctx.vm.dispatch(ctx, opcode, args);
            pcs = ctx.vm.nextPC;
        }

        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }
}
