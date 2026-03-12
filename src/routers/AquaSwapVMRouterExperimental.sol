// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { AquaOpcodesExpiremental } from "../opcodes/AquaOpcodesExpiremental.sol";

/// @title AquaSwapVMRouterExperimental
/// @notice Router with experimental fee instructions (feeOut, progressiveFee, protocolFeeOut)
contract AquaSwapVMRouterExperimental is Simulator, SwapVM, AquaOpcodesExpiremental {
    constructor(address aqua, address weth, string memory name, string memory version) SwapVM(aqua, weth, name, version) AquaOpcodesExpiremental(aqua) { }

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
