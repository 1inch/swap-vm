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
        ROUTER = router;
        _ORDER_TYPEHASH = router.ORDER_TYPEHASH();
        _ROUTER_NAME_HASH = keccak256(bytes(name));
        _ROUTER_VERSION_HASH = keccak256(bytes(version));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();

        ISwapVM.Order memory probe = ISwapVM.Order({ maker: address(this), traits: MakerTraits.wrap(0), data: "probe" });
        require(
            _hashOrder(probe.maker, probe.traits, keccak256(probe.data)) == router.hash(probe),
            RouterOrderHashMismatch()
        );
    }

    function _hashOrder(address maker, MakerTraits traits, bytes32 dataHash) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(_ORDER_TYPEHASH, maker, traits, dataHash));
        return MessageHashUtils.toTypedDataHash(_routerDomainSeparator(), structHash);
    }

    /// @dev False on a fork with a new chain ID: immutables keep the deployment one.
    function _isDeploymentChain() internal view returns (bool) {
        return block.chainid == _CACHED_CHAIN_ID;
    }

    function _routerDomainSeparator() private view returns (bytes32) {
        return _isDeploymentChain() ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _ROUTER_NAME_HASH, _ROUTER_VERSION_HASH, block.chainid, address(ROUTER))
        );
    }
}
