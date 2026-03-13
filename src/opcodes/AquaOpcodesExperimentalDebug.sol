// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

import { AquaOpcodesExperimental } from "./AquaOpcodesExperimental.sol";
import { Debug } from "../instructions/Debug.sol";

contract AquaOpcodesExperimentalDebug is AquaOpcodesExperimental, Debug {
    constructor(address aqua) AquaOpcodesExperimental(aqua) {}

    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _injectDebugOpcodes(super._opcodes());
    }
}
