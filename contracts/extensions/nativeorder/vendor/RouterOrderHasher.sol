// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { ISwapVM } from "../../../interfaces/ISwapVM.sol";
import { MakerTraits } from "../../../libs/MakerTraits.sol";
import { EIP712Alien } from "./EIP712Alien.sol";

/// @title RouterOrderHasher
/// @notice Computes SwapVM signature-order hashes locally, byte-identical to `ROUTER.hash(order)`,
/// without an external call and from `keccak256(order.data)` alone.
/// @dev Covers only the EIP-712 branch of `SwapVM.hash`; Aqua orders must be rejected by the inheritor.
abstract contract RouterOrderHasher is EIP712Alien {
    bytes32 private immutable _ORDER_TYPEHASH;

    constructor(ISwapVM router) EIP712Alien(address(router)) {
        _ORDER_TYPEHASH = router.ORDER_TYPEHASH();
    }

    /// @dev Equals `ROUTER.hash(Order(maker, traits, data))` for non-Aqua traits, given `dataHash = keccak256(data)`.
    function _hashOrder(address maker, MakerTraits traits, bytes32 dataHash) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(_ORDER_TYPEHASH, maker, traits, dataHash));
        return _hashTypedDataV4(structHash);
    }
}
