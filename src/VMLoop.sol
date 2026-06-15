// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context, ContextLib } from "./libs/VM.sol";

abstract contract VMLoop {
    using ContextLib for Context;

    /// @dev Override in the opcode set to dispatch an opcode index to its instruction handler.
    ///      Replaces the per-call function-pointer table: it is set once into the VM context and
    ///      invoked by {ContextLib.runLoop} for every instruction.
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
        require(ctx.vm.nextPC < programBytes.length, ContextLib.RunLoopExcessiveCall(ctx.vm.nextPC, programBytes.length));

        for (uint256 pcs = ctx.vm.nextPC; pcs < programBytes.length; ) {
            unchecked {
                uint256 opcode;
                assembly ("memory-safe") {
                    opcode := shr(248, calldataload(add(programBytes.offset, pcs)))
                }
                ++pcs;

                uint256 argsLength;
                assembly ("memory-safe") {
                    argsLength := shr(248, calldataload(add(programBytes.offset, pcs)))
                }
                ++pcs;

                bytes calldata args;
                assembly ("memory-safe") {
                    args.offset := add(programBytes.offset, pcs)
                    args.length := argsLength
                }

                ctx.vm.nextPC = pcs + argsLength;
                _runOpcode(ctx, opcode, args);
                pcs = ctx.vm.nextPC;
            }
        }
    }
}
