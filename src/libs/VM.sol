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

    /// @dev Program counter exceeds program length
    error RunLoopExcessiveCall(uint256 pc, uint256 programLength);

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
    /// @dev LIMITATION: Program size is effectively limited to 65,535 bytes due to Controls
    ///      jump instructions using uint16 addressing. Programs exceeding this size can execute,
    ///      but jump instructions cannot address positions >= 65,536. For custom control flow in
    ///      larger programs, use Extruction._extruction which supports arbitrary uint256 nextPC.
    /// @param ctx Execution context containing program and registers
    /// @return swapAmountIn Final computed input amount
    /// @return swapAmountOut Final computed output amount
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
