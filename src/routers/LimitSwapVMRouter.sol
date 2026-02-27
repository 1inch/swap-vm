// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { Context } from "../libs/VM.sol";
import { SwapVM } from "../SwapVM.sol";
import { LimitOpcodes } from "../opcodes/LimitOpcodes.sol";

/// @title LimitSwapVMRouter
/// @notice Router with time-based order execution (limit orders, TWAP, Dutch auctions)
/// @dev Extends SwapVMRouter with LimitOpcodes for time-dependent swap strategies
contract LimitSwapVMRouter is Simulator, SwapVM, LimitOpcodes {
    /// @notice Deploy router with Aqua and WETH addresses
    /// @param aqua Address of Aqua protocol for balance management
    /// @param weth Address of WETH token for unwrapping support
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    constructor(address aqua, address weth, string memory name, string memory version) SwapVM(aqua, weth, name, version) LimitOpcodes(aqua) { }

    /// @dev Returns instruction set for VM execution
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
