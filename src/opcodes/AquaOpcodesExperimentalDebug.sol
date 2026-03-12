// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

import { AquaOpcodesExpiremental } from "./AquaOpcodesExpiremental.sol";
import { Debug } from "../instructions/Debug.sol";

contract AquaOpcodesExperimentalDebug is AquaOpcodesExpiremental, Debug {
    constructor(address aqua) AquaOpcodesExpiremental(aqua) {}

    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _injectDebugOpcodes(super._opcodes());
    }
}
