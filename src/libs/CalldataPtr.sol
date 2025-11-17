// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

// struct CalldataPtr {
//     uint128 offset;
//     uint128 length;
// }
type CalldataPtr is uint256;

library CalldataPtrLib {
    using CalldataPtrLib for CalldataPtr;

    function from(bytes calldata data) internal pure returns (CalldataPtr ptr) {
        assembly ("memory-safe") {
            ptr := or(shl(128, data.offset), data.length)
        }
    }

    function toBytes(CalldataPtr ptr) internal pure returns (bytes calldata data) {
        assembly ("memory-safe") {
            data.offset := shr(128, ptr)
            data.length := and(ptr, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }
}
