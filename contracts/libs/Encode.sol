// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

library Encode {
    error EncodeBitExceedsByte(uint256 bit);

    /// @notice Encode bool as left-aligned bit in byte
    function bit(bool value, uint8 at) internal pure returns (uint8 res) {
        require(at < 8, EncodeBitExceedsByte(at));
        if (value) res = uint8(128 >> at);
    }

    /// @notice Encode right half of address
    /// @dev Designed for taker validation, not suitable for parameters validation
    function halfAddress(address value) internal pure returns (uint80 res) {
        res = uint80(uint160(value));
    }
}
