// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { MakerTraits } from "../../libs/MakerTraits.sol";

/// @dev Native order parameters used to derive the escrow CREATE2 salt
struct NativeOrder {
    MakerTraits _traits;
    bytes32 _dataHash;
    uint256 _packed; // [uint56 maxBaseFee, uint40 expiration, address maker]
}

using NativeOrderLib for NativeOrder global;

library NativeOrderLib {
    uint256 internal constant SIZE = 0x60;

    function encode(
        address maker_,
        MakerTraits traits_,
        bytes32 dataHash_,
        uint40 expiration_,
        uint56 maxBaseFee_
    ) internal pure returns (NativeOrder memory) {
        return NativeOrder({
            _traits: traits_,
            _dataHash: dataHash_,
            _packed: (uint256(maxBaseFee_) << 200) | (uint256(expiration_) << 160) | uint160(maker_)
        });
    }

    /// @dev Expects signature.length == SIZE; does not validate the length
    function wrap(bytes calldata signature) internal pure returns (NativeOrder calldata order) {
        assembly ("memory-safe") { order := signature.offset }
    }

    function maker(NativeOrder calldata order) internal pure returns (address) {
        return address(uint160(order._packed));
    }

    function traits(NativeOrder calldata order) internal pure returns (MakerTraits) {
        return order._traits;
    }

    function dataHash(NativeOrder calldata order) internal pure returns (bytes32) {
        return order._dataHash;
    }

    function expiration(NativeOrder calldata order) internal pure returns (uint40) {
        return uint40(order._packed >> 160);
    }

    function maxBaseFee(NativeOrder calldata order) internal pure returns (uint56) {
        return uint56(order._packed >> 200);
    }

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
