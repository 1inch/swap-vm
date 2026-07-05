// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/Opcodes.sol";

import { Opcodes } from "./Opcodes.sol";
import { Debug } from "../instructions/Debug.sol";

contract OpcodesDebug is Opcodes, Debug {
    constructor(address aqua) Opcodes(aqua) {}

    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
             if (opcode == uint256(Opcode.PrintSwapRegisters)) Debug._printSwapRegisters(ctx, args);
        else if (opcode == uint256(Opcode.PrintSwapQuery)) Debug._printSwapQuery(ctx, args);
        else if (opcode == uint256(Opcode.PrintContext)) Debug._printContext(ctx, args);
        else if (opcode == uint256(Opcode.PrintFreeMemoryPointer)) Debug._printFreeMemoryPointer(ctx, args);
        else if (opcode == uint256(Opcode.PrintGasLeft)) Debug._printGasLeft(ctx, args);
        else if (opcode == uint256(Opcode.PatchSwapRegisters)) Debug._patchSwapRegisters(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
