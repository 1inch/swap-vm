// SPDX-License-Identifier: MIT
// Vendored from 1inch/cross-chain-swap @ 8b806e28ac00d3749886cb05fad7b2826c7fe743
// (contracts/libraries/ProxyHashLib.sol). Logic unchanged.

pragma solidity ^0.8.20;

/**
 * @title Library to compute the hash of the proxy bytecode.
 * @custom:security-contact security@1inch.io
 */
library ProxyHashLib {
    /**
     * @notice Returns the hash of the proxy bytecode concatenated with the implementation address.
     * @param implementation The address of the contract to clone.
     * @return bytecodeHash The hash of the resulting bytecode.
     */
    function computeProxyBytecodeHash(address implementation) internal pure returns (bytes32 bytecodeHash) {
        assembly ("memory-safe") {
            // Stores the bytecode after address
            mstore(0x20, 0x5af43d82803e903d91602b57fd5bf3)
            // implementation address
            mstore(0x11, implementation)
            // Packs the first 3 bytes of the `implementation` address with the bytecode before the address.
            mstore(0x00, or(shr(0x88, implementation), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            bytecodeHash := keccak256(0x09, 0x37)
        }
    }
}
