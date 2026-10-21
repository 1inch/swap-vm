// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { MakerTraits } from "../../../libs/MakerTraits.sol";

/// @notice Terms committed in the escrow's CREATE2 address, read through the NativeOrderLib getters.
/// @dev Fixed-size fields only: their abi.encode (128 bytes) is the signature, its keccak256 the salt.
struct NativeOrder {
    address _maker;
    MakerTraits _traits;
    bytes32 _dataHash;
    uint256 _expirationAndMaxReward; // maxReward << 40 | expiration
}

using NativeOrderLib for NativeOrder global;

/// @title NativeOrderLib
/// @notice Encoding, field getters and CREATE2 salt calculation for `NativeOrder`.
library NativeOrderLib {
    uint256 internal constant SIZE = 0x80;

    function maker(NativeOrder calldata order) internal pure returns (address) {
        return order._maker;
    }

    function traits(NativeOrder calldata order) internal pure returns (MakerTraits) {
        return order._traits;
    }

    /// @dev keccak256 of the maker order's data.
    function dataHash(NativeOrder calldata order) internal pure returns (bytes32) {
        return order._dataHash;
    }

    /// @dev Fills are rejected from this timestamp.
    function expiration(NativeOrder calldata order) internal pure returns (uint40) {
        return uint40(order._expirationAndMaxReward);
    }

    /// @dev Max native ETH paid to a public canceller.
    function maxReward(NativeOrder calldata order) internal pure returns (uint96) {
        return uint96(order._expirationAndMaxReward >> 40);
    }

    function encode(
        address orderMaker,
        MakerTraits orderTraits,
        bytes32 orderDataHash,
        uint40 orderExpiration,
        uint96 orderMaxReward
    ) internal pure returns (NativeOrder memory) {
        return NativeOrder({
            _maker: orderMaker,
            _traits: orderTraits,
            _dataHash: orderDataHash,
            _expirationAndMaxReward: (uint256(orderMaxReward) << 40) | orderExpiration
        });
    }

    /// @dev Expects signature.length == SIZE and does not check it.
    function decode(bytes calldata signature) internal pure returns (NativeOrder calldata order) {
        assembly ("memory-safe") { order := signature.offset }
    }

    /// @dev Hashes the calldata words as they are, so a noncanonical encoding gets a different salt.
    function salt(NativeOrder calldata order) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, order, SIZE)
            result := keccak256(ptr, SIZE)
        }
    }

    function saltMemory(NativeOrder memory order) internal pure returns (bytes32 result) {
        assembly ("memory-safe") { result := keccak256(order, SIZE) }
    }
}
