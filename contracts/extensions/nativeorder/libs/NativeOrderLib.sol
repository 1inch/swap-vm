// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { MakerTraits } from "../../../libs/MakerTraits.sol";

/// @notice Terms committed in the escrow's CREATE2 address.
/// @dev Fixed-size fields only: their abi.encodePacked (101 bytes) is the signature, its keccak256 the salt.
struct NativeOrder {
    address maker;
    MakerTraits traits;
    bytes32 dataHash; // keccak256(order.data)
    uint40 expiration; // fills are rejected from this timestamp
    uint96 maxReward; // max native ETH paid to a public canceller
}

using NativeOrderLib for NativeOrder global;

/// @title NativeOrderLib
/// @notice Packing, calldata decoding and CREATE2 salt calculation for `NativeOrder`.
library NativeOrderLib {
    uint256 internal constant SIZE = 101; // 20 + 32 + 32 + 5 + 12

    function encode(NativeOrder memory order) internal pure returns (bytes memory) {
        return abi.encodePacked(order.maker, order.traits, order.dataHash, order.expiration, order.maxReward);
    }

    /// @dev Expects signature.length == SIZE and does not check it.
    function decode(bytes calldata signature)
        internal pure
        returns (address maker, MakerTraits traits, bytes32 dataHash, uint40 expiration, uint96 maxReward)
    {
        assembly ("memory-safe") {
            maker := shr(96, calldataload(signature.offset))
            traits := calldataload(add(signature.offset, 20))
            dataHash := calldataload(add(signature.offset, 52))
            expiration := shr(216, calldataload(add(signature.offset, 84)))
            maxReward := shr(160, calldataload(add(signature.offset, 89)))
        }
    }

    /// @dev Expects signature.length == SIZE and does not check it.
    function salt(bytes calldata signature) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, signature.offset, SIZE)
            result := keccak256(ptr, SIZE)
        }
    }

    /// @dev Shifts drop dirty high bits; Solidity's calldata validation rejects them when the fields are read.
    function salt(NativeOrder calldata order) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(96, calldataload(order)))
            mstore(add(ptr, 20), calldataload(add(order, 0x20)))
            mstore(add(ptr, 52), calldataload(add(order, 0x40)))
            mstore(add(ptr, 84), shl(216, calldataload(add(order, 0x60))))
            mstore(add(ptr, 89), shl(160, calldataload(add(order, 0x80))))
            result := keccak256(ptr, SIZE)
        }
    }

    function saltMemory(NativeOrder memory order) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(96, mload(order)))
            mstore(add(ptr, 20), mload(add(order, 0x20)))
            mstore(add(ptr, 52), mload(add(order, 0x40)))
            mstore(add(ptr, 84), shl(216, mload(add(order, 0x60))))
            mstore(add(ptr, 89), shl(160, mload(add(order, 0x80))))
            result := keccak256(ptr, SIZE)
        }
    }
}
