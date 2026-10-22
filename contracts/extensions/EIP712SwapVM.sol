// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC5267 } from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { MakerTraits } from "../libs/MakerTraits.sol";

/// @title EIP712SwapVM
/// @notice Allows third-party contract to get SwapVM order hashed without external call
abstract contract EIP712SwapVM {
    bytes32 private constant _DOMAIN_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = keccak256("Order(address maker,uint256 traits,bytes data)");

    address private immutable _SWAP_VM_ROUTER;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    constructor(address router) {
        (, string memory name, string memory version,,,,) = IERC5267(router).eip712Domain();
        _SWAP_VM_ROUTER = router;
        _HASHED_NAME = keccak256(bytes(name));
        _HASHED_VERSION = keccak256(bytes(version));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    function _hashOrder(address maker, MakerTraits traits, bytes32 dataHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), keccak256(abi.encode(_TYPE_HASH, maker, traits, dataHash)));
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_HASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, _SWAP_VM_ROUTER));
    }
}
