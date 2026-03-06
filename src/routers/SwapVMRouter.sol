// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { Opcodes } from "../opcodes/Opcodes.sol";

/// @title SwapVMRouter
/// @notice Standard router with signature-based order execution and basic swap instructions
/// @dev Inherits SwapVM execution engine with Opcodes instruction set (XYC, Pegged, Fee, etc.)
contract SwapVMRouter is Simulator, SwapVM, Opcodes {
    /// @notice Deploy router with Aqua and WETH addresses
    /// @param aqua Address of Aqua protocol for balance management
    /// @param weth Address of WETH token for unwrapping support
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    constructor(address aqua, address weth, string memory name, string memory version, address owner) SwapVM(aqua, weth, name, version, owner) Opcodes(aqua) { }

    /// @dev Returns instruction set for VM execution
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
