// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IMakerHooks } from "../../src/interfaces/IMakerHooks.sol";

/// @dev Mock that reverts on specific hooks for testing
contract RevertingMakerHooks {
    enum HookType { None, PreTransferIn, PostTransferIn, PreTransferOut, PostTransferOut }

    error PreTransferInReverted();
    error PostTransferInReverted();
    error PreTransferOutReverted();
    error PostTransferOutReverted();

    HookType public revertOn;

    function setRevertOn(HookType hookType) external {
        revertOn = hookType;
    }

    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata) external view {
        if (revertOn == HookType.PreTransferIn) revert PreTransferInReverted();
    }

    function postTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata) external view {
        if (revertOn == HookType.PostTransferIn) revert PostTransferInReverted();
    }

    function preTransferOut(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata) external view {
        if (revertOn == HookType.PreTransferOut) revert PreTransferOutReverted();
    }

    function postTransferOut(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata) external view {
        if (revertOn == HookType.PostTransferOut) revert PostTransferOutReverted();
    }
}
