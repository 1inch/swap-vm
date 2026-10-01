// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { MakerTraits } from "../../libs/MakerTraits.sol";

/// @title RouterOrderHasher
/// @notice Computes SwapVM signature-order hashes locally, byte-identical to `ROUTER.hash(order)`,
/// without an external call and from `keccak256(order.data)` alone.
/// @dev Covers only the EIP-712 branch of `SwapVM.hash`; Aqua orders must be rejected by the inheritor.
abstract contract RouterOrderHasher {
    error RouterOrderHashMismatch();

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _ORDER_TYPEHASH = keccak256("Order(address maker,uint256 traits,bytes data)");

    address private immutable _ROUTER;
    bytes32 private immutable _ROUTER_NAME_HASH;
    bytes32 private immutable _ROUTER_VERSION_HASH;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    constructor(ISwapVM router) {
        (, string memory name, string memory version,,,,) = IERC5267(address(router)).eip712Domain();
        bytes32 nameHash = keccak256(bytes(name));
        bytes32 versionHash = keccak256(bytes(version));
        bytes32 domainSeparator = _buildDomainSeparator(address(router), nameHash, versionHash);

        ISwapVM.Order memory probe = ISwapVM.Order({ maker: address(this), traits: MakerTraits.wrap(0), data: "probe" });
        if (_typedOrderHash(domainSeparator, probe.maker, probe.traits, keccak256(probe.data)) != router.hash(probe)) {
            revert RouterOrderHashMismatch();
        }

        _ROUTER = address(router);
        _ROUTER_NAME_HASH = nameHash;
        _ROUTER_VERSION_HASH = versionHash;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = domainSeparator;
    }

    /// @dev Equals `ROUTER.hash(Order(maker, traits, data))` for non-Aqua traits, given `dataHash = keccak256(data)`.
    function _hashOrder(address maker, MakerTraits traits, bytes32 dataHash) internal view returns (bytes32) {
        return _typedOrderHash(_routerDomainSeparator(), maker, traits, dataHash);
    }

    function _typedOrderHash(bytes32 domainSeparator, address maker, MakerTraits traits, bytes32 dataHash)
        private
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(_ORDER_TYPEHASH, maker, traits, dataHash));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    function _routerDomainSeparator() private view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _CACHED_DOMAIN_SEPARATOR;
        return _buildDomainSeparator(_ROUTER, _ROUTER_NAME_HASH, _ROUTER_VERSION_HASH);
    }

    function _buildDomainSeparator(address router, bytes32 nameHash, bytes32 versionHash) private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, router));
    }
}
