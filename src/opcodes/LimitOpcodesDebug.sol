// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

import { LimitOpcodes } from "./LimitOpcodes.sol";
import { Debug } from "../instructions/Debug.sol";

contract LimitOpcodesDebug is LimitOpcodes, Debug {
    constructor(address aqua) LimitOpcodes(aqua) {}

    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _injectDebugOpcodes(super._opcodes());
    }

    /// @dev Debug build: opcodes 0-4 are debug utilities; all others defer to the production dispatcher.
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode == 0) Debug._printSwapRegisters(ctx, args);
        else if (opcode == 1) Debug._printSwapQuery(ctx, args);
        else if (opcode == 2) Debug._printContext(ctx, args);
        else if (opcode == 3) Debug._printFreeMemoryPointer(ctx, args);
        else if (opcode == 4) Debug._printGasLeft(ctx, args);
        else super._runOpcode(ctx, opcode, args);
    }
}
