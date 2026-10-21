// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { MakerTraits } from "../../libs/MakerTraits.sol";
import { IRouterOrderHasher } from "./interfaces/IRouterOrderHasher.sol";

/// @title RouterOrderHasher
/// @notice Computes `ROUTER.hash(order)` locally for signature orders, from `keccak256(order.data)`.
/// @dev Aqua orders hash differently; inheritors must reject them.
abstract contract RouterOrderHasher is IRouterOrderHasher {
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    ISwapVM public immutable ROUTER;
    bytes32 private immutable _ORDER_TYPEHASH;
    bytes32 private immutable _ROUTER_NAME_HASH;
    bytes32 private immutable _ROUTER_VERSION_HASH;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    /// @dev Reverts if a probe order hashes differently than `router.hash`.
    constructor(ISwapVM router) {
        (, string memory name, string memory version,,,,) = IERC5267(address(router)).eip712Domain();
        bytes32 nameHash = keccak256(bytes(name));
        bytes32 versionHash = keccak256(bytes(version));
        bytes32 domainSeparator = _buildDomainSeparator(address(router), nameHash, versionHash);
        bytes32 orderTypehash = router.ORDER_TYPEHASH();

        ISwapVM.Order memory probe = ISwapVM.Order({ maker: address(this), traits: MakerTraits.wrap(0), data: "probe" });
        if (
            _typedOrderHash(orderTypehash, domainSeparator, probe.maker, probe.traits, keccak256(probe.data)) !=
            router.hash(probe)
        ) revert RouterOrderHashMismatch();

        ROUTER = router;
        _ORDER_TYPEHASH = orderTypehash;
        _ROUTER_NAME_HASH = nameHash;
        _ROUTER_VERSION_HASH = versionHash;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = domainSeparator;
    }

    function _hashOrder(address maker, MakerTraits traits, bytes32 dataHash) internal view returns (bytes32) {
        return _typedOrderHash(_ORDER_TYPEHASH, _routerDomainSeparator(), maker, traits, dataHash);
    }

    /// @dev False on a fork with a new chain ID: immutables keep the deployment one.
    function _isDeploymentChain() internal view returns (bool) {
        return block.chainid == _CACHED_CHAIN_ID;
    }

    function _typedOrderHash(
        bytes32 orderTypehash,
        bytes32 domainSeparator,
        address maker,
        MakerTraits traits,
        bytes32 dataHash
    ) private pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(orderTypehash, maker, traits, dataHash));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    function _routerDomainSeparator() private view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _CACHED_DOMAIN_SEPARATOR;
        return _buildDomainSeparator(address(ROUTER), _ROUTER_NAME_HASH, _ROUTER_VERSION_HASH);
    }

    function _buildDomainSeparator(address router, bytes32 nameHash, bytes32 versionHash) private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, router));
    }
}
