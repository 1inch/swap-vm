// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @dev ERC20 mock that returns false on transfer
contract ERC20ReturnFalseMock {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}
