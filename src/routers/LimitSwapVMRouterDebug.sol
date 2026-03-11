// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { Context } from "../libs/VM.sol";
import { SwapVM } from "../SwapVM.sol";
import { LimitOpcodesDebug } from "../opcodes/LimitOpcodesDebug.sol";

contract LimitSwapVMRouterDebug is Simulator, SwapVM, LimitOpcodesDebug {
    /// @notice Deploy router with Aqua and WETH addresses
    /// @param aqua Address of Aqua protocol for balance management
    /// @param weth Address of WETH token for unwrapping support
    /// @param owner Address of the owner of the router. Only owner can rescue funds.
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    constructor(address aqua, address weth, address owner, string memory name, string memory version) SwapVM(aqua, weth, owner, name, version) LimitOpcodesDebug(aqua) { }

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _opcodes();
    }
}
