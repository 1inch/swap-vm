// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode, OpcodeOps } from "../libs/OpcodeList.sol";

import { Opcodes } from "./Opcodes.sol";
import { PrintSwapRegisters, PrintSwapQuery, PrintVM, PrintFreeMemoryPointer, PrintGasLeft, PatchSwapRegisters } from "../instructions/Debug.sol";

contract OpcodesDebug is Opcodes {
    using OpcodeOps for Opcode;

    constructor(address aqua) Opcodes(aqua) {}

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
             if (opcode == PrintSwapRegisters.opcode.asU8()) PrintSwapRegisters.exec(ctx, args);
        else if (opcode == PrintSwapQuery.opcode.asU8()) PrintSwapQuery.exec(ctx, args);
        else if (opcode == PrintVM.opcode.asU8()) PrintVM.exec(ctx, args);
        else if (opcode == PrintFreeMemoryPointer.opcode.asU8()) PrintFreeMemoryPointer.exec(ctx, args);
        else if (opcode == PrintGasLeft.opcode.asU8()) PrintGasLeft.exec(ctx, args);
        else if (opcode == PatchSwapRegisters.opcode.asU8()) PatchSwapRegisters.exec(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
