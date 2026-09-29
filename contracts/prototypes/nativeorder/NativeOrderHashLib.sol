// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { MakerTraits } from "../../libs/MakerTraits.sol";

/// @title NativeOrderHashLib
/// @notice Local EIP-712 Order hashing matching SwapVM.hash for non-Aqua orders.
/// @dev Used by NativeOrderEscrow / Factory to avoid external ROUTER.hash calls (and the ABI
/// re-encoding of program bytes that comes with them). Domain separator is snapshotted at
/// construction; a chain-id fork would desync from the router (same as most cached-domain designs).
library NativeOrderHashLib {
    /// @dev Must match SwapVM.ORDER_TYPEHASH.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order("
            "address maker,"
            "uint256 traits,"
            "bytes data"
        ")"
    );

    /// @dev EIP-712 domain typehash used by OpenZeppelin EIP712 (no salt).
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Builds the router's EIP-712 domain separator via IERC5267.
    function domainSeparator(address router) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            IERC5267(router).eip712Domain();
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
    }

    /// @notice EIP-712 digest for an order, given a precomputed `keccak256(data)`.
    function hashOrder(bytes32 domainSep, address maker, MakerTraits traits, bytes32 dataHash)
        internal
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(
            domainSep, keccak256(abi.encode(ORDER_TYPEHASH, maker, traits, dataHash))
        );
    }
}
