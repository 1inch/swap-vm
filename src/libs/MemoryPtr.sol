// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

/// @dev Allocated memory pointer: [uint48, uint80 current, uint64 end, uint64 start]
///   start -> slice start pointer, leaves first word for slice length
///   current -> write pointer, initialized with start + 32
///   end -> allocation end pointer, start + 32 + length
/// @dev Allocated with `alloc`, returns slice at `resolve` checking allocation is not exceeded
///   Due to lazy write bounds check, every pointer should be resolved with `resolve`, `resolveShrink` or `patch`
/// @dev Memory written with `push` returning pointer with updated `current` value
/// @dev Memory patched with `patch` at specified byte reached with `skip`
/// @dev Any pointer reflecting allocated space fit uint64 due to 2 ** 64 bytes allocation costs 1e32 Gas
///   Consecutive additions of uint24 to uint64 would not exceed uint80 due to this requires 7e16 operations
///   It is safe to increase `current` unchecked for uint24 values or while this reflects real memory write length
type MemoryPtr is uint256;

library MemoryPtrLib {
    error MemoryPtrWriteOutOfBounds(uint256 end, uint256 current);
    error MemoryPtrStrictResolveFailed(uint256 end, uint256 current);
    error MemoryPtrBaseMismatch(MemoryPtr, MemoryPtr);
    error MemoryPtrSkipTooMuch(uint256 size);
    error MemoryPtrAllocTooMuch(uint256 size);

    function alloc(uint256 length) internal pure returns (MemoryPtr ptr) {
        require(length >> 64 == 0, MemoryPtrAllocTooMuch(length)); // length <= type(uint64).max

        // Allocate length + 1 additional word potentially zeroed by `_push`
        assembly ("memory-safe") {
            ptr := mload(0x40)
            mstore(0x40, add(ptr, and(add(add(length, 64), 31), not(31)))) // freeMemPtr % 32 == 0
            calldatacopy(ptr, calldatasize(), add(length, 32)) // zeroize + memory expansion
            mstore(ptr, length) // store length
        }
        // current = start + 32, end = start + 32 + length
        // packing: current << 128 | end << 64 | start
        unchecked {
            ptr = MemoryPtr.wrap(
                ((MemoryPtr.unwrap(ptr) + 32) << 128) |
                (MemoryPtr.unwrap(ptr) + 32 + length) << 64 |
                MemoryPtr.unwrap(ptr)
            );
        }
    }

    function resolve(MemoryPtr ptr) internal pure returns (bytes memory) {
        (bytes memory slice, uint256 end, uint256 current) = _resolve(ptr);
        require(end == current, MemoryPtrStrictResolveFailed(end, current));

        return slice;
    }

    /// @dev Prefer exact resolve if possible 
    function resolveShrink(MemoryPtr ptr) internal pure returns (bytes memory, uint256 shrink) {
        (bytes memory slice, uint256 end, uint256 current) = _resolve(ptr);
        require(end >= current, MemoryPtrWriteOutOfBounds(end, current));

        unchecked { shrink = end - current; }
        assembly ("memory-safe") { mstore(slice, sub(current, add(slice, 32))) } // length = current - (start + 1 word)

        return (slice, shrink);
    }

    function sub(MemoryPtr hi, MemoryPtr lo) internal pure returns (uint256 diff) {
        diff = MemoryPtr.unwrap(hi) - MemoryPtr.unwrap(lo);
        // Subtraction supported only for pointers with same base
        require(diff << 128 == 0, MemoryPtrBaseMismatch(hi, lo));
        return diff >> 128;
    }

    function _resolve(MemoryPtr ptr) private pure returns (bytes memory slice, uint256 end, uint256 current) {
        assembly ("memory-safe") {
            slice := and(ptr, 0xffffffffffffffff) // start: last 8 bytes
            end := and(shr(64, ptr), 0xffffffffffffffff) // end: next 8 bytes
            current := shr(128, ptr)
        }
    }

    function _move(MemoryPtr ptr, uint256 size) private pure returns (MemoryPtr) {
        unchecked { return MemoryPtr.wrap(MemoryPtr.unwrap(ptr) + (size << 128)); } // current += size
    }

    function _push(MemoryPtr ptr, bytes32 value, uint8 size) private pure returns (MemoryPtr) {
        assembly ("memory-safe") { mstore(shr(128, ptr), value) } // memory[current:+size) = value
        return _move(ptr, size);
    }

    function _push8(MemoryPtr ptr, uint8 value) private pure returns (MemoryPtr) {
        assembly ("memory-safe") { mstore8(shr(128, ptr), value) } // memory[current] = value
        return _move(ptr, 1);
    }

    function _patch(MemoryPtr ptr, bytes32 value, uint8 size) private pure {
        assembly ("memory-safe") { // memory[current:+32) = value | memory[current+size:+32-size)
            mstore(shr(128, ptr), or(value, and(mload(shr(128, ptr)), shr(shl(3, size), not(0)))))
        }

        (, uint256 end, uint256 current) = _resolve(_move(ptr, size));
        require(end >= current, MemoryPtrWriteOutOfBounds(end, current));
    }

    function _patch8(MemoryPtr ptr, uint8 value) private pure {
        assembly ("memory-safe") { mstore8(shr(128, ptr), value) } // memory[current] = value

        (, uint256 end, uint256 current) = _resolve(_move(ptr, 1));
        require(end >= current, MemoryPtrWriteOutOfBounds(end, current));
    }

    function skip(MemoryPtr ptr, uint256 size) internal pure returns (MemoryPtr) {
        require(size >> 24 == 0, MemoryPtrSkipTooMuch(size)); // size <= type(uint24).max
        return _move(ptr, size);
    }

    function push(MemoryPtr ptr, bytes calldata data) internal pure returns (MemoryPtr) {
        uint256 length = data.length;
        assembly ("memory-safe") { calldatacopy(shr(128, ptr), data.offset, length) } // memory[current:+length) = data
        return _move(ptr, length);
    }

    /// @dev Prefer allocating space once and build everything there
    function pushMem(MemoryPtr ptr, bytes memory data) internal pure returns (MemoryPtr) {
        uint256 length = data.length;
        assembly ("memory-safe") { mcopy(shr(128, ptr), add(data, 32), length) } // memory[current:+length) = data
        return _move(ptr, length);
    }

    function push(MemoryPtr ptr, address value) internal pure returns (MemoryPtr) { return _push(ptr, bytes20(value), 20); }

    function push(MemoryPtr ptr, bytes1 value) internal pure returns (MemoryPtr) { return _push8(ptr, uint8(value)); }
    function push(MemoryPtr ptr, bytes32 value, uint8 size) internal pure returns (MemoryPtr) { return _push(ptr, value, size); }

    function push(MemoryPtr ptr, uint8 value) internal pure returns (MemoryPtr) { return _push8(ptr, value); }
    function push(MemoryPtr ptr, uint256 value, uint8 size) internal pure returns (MemoryPtr) {
        return _push(ptr, bytes32(value << ((32 - uint256(size)) << 3)), size);
    }

    function patch(MemoryPtr ptr, address value) internal pure { _patch(ptr, bytes20(value), 20); }

    function patch(MemoryPtr ptr, bytes1 value) internal pure { _patch8(ptr, uint8(value)); }
    function patch(MemoryPtr ptr, bytes32 value, uint8 size) internal pure {
        _patch(ptr, value & bytes32(type(uint256).max << ((32 - uint256(size)) << 3)), size);
    }

    function patch(MemoryPtr ptr, uint8 value) internal pure { _patch8(ptr, value); }
    function patch(MemoryPtr ptr, uint256 value, uint8 size) internal pure {
        _patch(ptr, bytes32(value << ((32 - uint256(size)) << 3)), size);
    }
}
