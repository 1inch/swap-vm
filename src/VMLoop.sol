// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context, ContextLib } from "./libs/VM.sol";

abstract contract VMLoop {
    using ContextLib for Context;

    /// @dev Override in the opcode set to dispatch an opcode index to its instruction handler
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual;

    /// @notice Execute program instructions sequentially
    /// @dev Iterates through bytecode, executing each instruction until program end
    /// @dev LIMITATION: Program size is effectively limited to 65,535 bytes due to Controls
    ///      jump instructions using uint16 addressing. Programs exceeding this size can execute,
    ///      but jump instructions cannot address positions >= 65,536. For custom control flow in
    ///      larger programs, use Extruction._extruction which supports arbitrary uint256 nextPC.
    /// @param ctx Execution context containing program and registers
    function _runLoop(Context memory ctx) internal virtual {
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
            if (pcs > length) revert ContextLib.RunLoopExceedProgramLength(pcs, length);

            ctx.vm.nextPC = pcs;
            _runOpcode(ctx, opcode, args);
            pcs = ctx.vm.nextPC;
        }
    }
}
