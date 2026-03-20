// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KycNft
/// @notice Simple ERC-721 for KYC-gating swap strategies.
///   Owner mints tokens to whitelisted addresses; holding >= 1 token
///   satisfies the `Controls._onlyTakerTokenBalanceNonZero` check.
contract KycNft is ERC721, Ownable {
    uint256 private _nextId;

    constructor(address owner_) ERC721("SwapVM KYC", "SVMKYC") Ownable(owner_) {}

    /// @notice Mint a KYC token to `to`. Only callable by the owner.
    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(to, tokenId);
    }

    /// @notice Batch-mint KYC tokens to multiple addresses.
    function mintBatch(address[] calldata recipients) external onlyOwner {
        uint256 id = _nextId;
        for (uint256 i; i < recipients.length; ++i) {
            _mint(recipients[i], id++);
        }
        _nextId = id;
    }

    /// @notice Revoke KYC by burning a token. Only callable by the owner.
    function revoke(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }
}
