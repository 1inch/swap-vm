// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { StorageSlots } from "../libs/StorageSlots.sol";
import { TransientLock, TransientLockLib } from "@1inch/solidity-utils/contracts/libraries/TransientLock.sol";

/// @notice Provides order-scoped transient locks for swap execution
library ReentrancyProtection {
    using TransientLockLib for TransientLock;

    struct Storage {
        mapping(bytes32 orderHash => TransientLock) locks;
    }

    function _getStorage() private pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.ReentrancyProtection;
        assembly ("memory-safe") { $.slot := slot }
    }

    function _getLock(bytes32 orderHash) private view returns (TransientLock storage) {
        return _getStorage().locks[orderHash];
    }

    /// @notice Acquires the transient lock for an order
    function acquire(bytes32 orderHash) internal {
        _getLock(orderHash).lock();
    }

    /// @notice Releases the transient lock for an order
    function release(bytes32 orderHash) internal {
        _getLock(orderHash).unlock();
    }

    /// @notice Returns whether an order is currently locked
    function isLocked(bytes32 orderHash) internal view returns (bool) {
        return _getLock(orderHash).isLocked();
    }
}