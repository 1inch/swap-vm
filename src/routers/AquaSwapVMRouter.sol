// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { AquaOpcodes } from "../opcodes/AquaOpcodes.sol";

contract AquaSwapVMRouter is Simulator, SwapVM, AquaOpcodes {
    constructor(address aqua, string memory name, string memory version) SwapVM(aqua, name, version) AquaOpcodes(aqua) { }

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
