// SPDX-License-Identifier: MIT
// Vendored from 1inch/cross-chain-swap @ 8b806e28ac00d3749886cb05fad7b2826c7fe743
// (contracts/libraries/ImmutablesLib.sol).
// Fee getters omitted. `hash` and `hashMem` are unchanged, so the CREATE2 salt matches.

pragma solidity ^0.8.20;

import { IBaseEscrow } from "../interfaces/IBaseEscrow.sol";

/**
 * @title Library for escrow immutables.
 * @custom:security-contact security@1inch.io
 */
library ImmutablesLib {
    uint256 internal constant IMMUTABLES_SIZE = 0x120;
    uint256 internal constant IMMUTABLES_LAST_WORD = 0x100;

    /**
     * @notice Returns the hash of the immutables.
     * @param immutables The immutables to hash.
     * @return ret The computed hash.
     */
    function hash(IBaseEscrow.Immutables calldata immutables) internal pure returns(bytes32 ret) {
        // Compute the EIP-712 hash for the immutables struct
        bytes calldata parameters = immutables.parameters;
        assembly ("memory-safe") {
            let ptr := mload(0x40)

            // Copy immutables.parameters to memory and compute its hash
            calldatacopy(ptr, parameters.offset, parameters.length)
            let parametersHash := keccak256(ptr, parameters.length)

            // Copy the immutables struct to memory, patch `parameters` and compute its hash
            calldatacopy(ptr, immutables, IMMUTABLES_SIZE)
            mstore(add(ptr, IMMUTABLES_LAST_WORD), parametersHash)
            ret := keccak256(ptr, IMMUTABLES_SIZE)
        }
    }

    /**
     * @notice Returns the hash of the immutables.
     * @param immutables The immutables to hash.
     * @return ret The computed hash.
     */
    function hashMem(IBaseEscrow.Immutables memory immutables) internal pure returns(bytes32 ret) {
        // Compute the EIP-712 hash for the immutables struct
        // Patch the last word (bytes parameters) in the struct with the hash of it
        bytes memory parameters = immutables.parameters;
        assembly ("memory-safe") {
            let parametersHash := keccak256(add(parameters, 0x20), mload(parameters))
            let patchLocation := sub(add(immutables, IMMUTABLES_SIZE), 0x20)
            let backup := mload(patchLocation)

            // Patch the last word with the hash of parameters to compute the EIP-712 hash
            mstore(patchLocation, parametersHash)
            ret := keccak256(immutables, IMMUTABLES_SIZE)

            mstore(patchLocation, backup) // Restore the original value
        }
    }
}
