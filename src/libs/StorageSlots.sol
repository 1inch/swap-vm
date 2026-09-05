// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

/// @notice Precomputed ERC-7201 storage slots for stateful opcodes
library StorageSlots {
    // keccak256(abi.encode(uint256(keccak256("1inch.storage.DynamicBalances")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant DynamicBalances = 0x8a1457da782097e15d27dcace1e32c93a3c7def4809b9d7cbb5d279d9ef42e00;

    // keccak256(abi.encode(uint256(keccak256("1inch.storage.Decay")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant Decay = 0xdf4f9c8efeebb7ae953e0582cac77e36d5fcfec17c74962aa184e543e3701900;

    // keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateBit")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant InvalidateBit = 0x7fecc769dbd392886fe3a80cbebbd95af52350f470aa49fde0e0bc4a4d01b900;

    // keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateTokenIn")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant InvalidateTokenIn = 0xdec8baa2d3dc86177e0434fffbc83f7b9c94be3640a9bc75a6216af7c1874a00;

    // keccak256(abi.encode(uint256(keccak256("1inch.storage.InvalidateTokenOut")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant InvalidateTokenOut = 0x3c2634352eb2315e2005a08709d3df3f3b85b4a68fc7225cebee8d3fcbf55900;

    // keccak256(abi.encode(uint256(keccak256("1inch.storage.ValidateSeriesEpoch")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ValidateSeriesEpoch = 0xf6109436226f9396495ee71ea3d10edae6e620df596c3feca8428935dd6b1400;
}
