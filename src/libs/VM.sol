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

/// @dev A tokenIn fee owed by the maker, settled by SwapVM once the taker's tokenIn has been delivered
/// @param recipient The address the fee is paid to
/// @param useAqua Whether the fee is pulled through Aqua or transferred from the maker's wallet
/// @param amount The tokenIn amount owed
struct PendingFee {
    address recipient;
    bool useAqua;
    uint256 amount;
}

/// @title SwapVM context
/// @notice Complete execution state for a swap operation
/// @param vm The VM execution state including program counter and bytecode
/// @param query Read-only swap information (maker, taker, tokens, etc.)
/// @param swap Mutable registers for computing swap amounts
/// @param fees Fees on tokenIn accrued by the program, settled after the transfer phase
struct Context {
    VM vm;
    SwapQuery query;
    SwapRegisters swap;
    PendingFee[] fees;
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

    /// @notice Record a tokenIn fee owed by the maker for settlement after the transfer phase
    /// @dev Fee-on-amountIn instructions cannot move tokens while the program runs: the maker is only
    ///      credited with the taker's tokenIn once SwapVM reaches the transfer phase. Accruing here and
    ///      settling later keeps the fee payable out of the incoming amount instead of requiring the
    ///      maker to pre-fund tokenIn. Amounts for the same recipient and settlement path are merged.
    /// @param ctx Execution context
    /// @param recipient Address the fee is paid to
    /// @param useAqua Whether the fee is pulled through Aqua or transferred from the maker's wallet
    /// @param amount Fee amount in tokenIn
    function accrueFee(Context memory ctx, address recipient, bool useAqua, uint256 amount) internal pure {
        if (amount == 0) return;

        PendingFee[] memory fees = ctx.fees;
        uint256 length = fees.length;
        for (uint256 i = 0; i < length; i++) {
            if (fees[i].recipient == recipient && fees[i].useAqua == useAqua) {
                fees[i].amount += amount;
                return;
            }
        }

        PendingFee[] memory extended = new PendingFee[](length + 1);
        for (uint256 i = 0; i < length; i++) {
            extended[i] = fees[i];
        }
        extended[length] = PendingFee({ recipient: recipient, useAqua: useAqua, amount: amount });
        ctx.fees = extended;
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
