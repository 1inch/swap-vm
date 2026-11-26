// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Opcode } from "./OpcodeList.sol";
import { MemoryPtr } from "./MemoryPtr.sol";

library InstructionBuilder {
    error InstructionBuilderArgsLengthExceeded(uint256 length);
    error InstructionBuilderBitExceedsByte(uint256 bit);
    error InstructionBuilderArgsLengthMismatch();

    function sizeOf() internal pure returns (uint256) {
        return 2;
    }

    /// @notice Require `args` to be exactly the arguments of a `size`-byte instruction
    /// @dev `size` is the instruction `sizeOf()`, header included
    /// @dev Instruction parsers read `args` unchecked, missing bytes would be taken from whatever follows:
    ///   the next instructions or, at the program end, calldata which is not covered by the order hash
    function exactLength(uint256 size, bytes calldata args) internal pure {
        unchecked { require(args.length + sizeOf() == size, InstructionBuilderArgsLengthMismatch()); }
    }

    /// @notice Require `args` to cover the fixed part of an instruction which ends with free-form bytes
    /// @dev `size` is the instruction `sizeOf()` for the empty tail, header included
    function minLength(uint256 size, bytes calldata args) internal pure {
        unchecked { require(args.length + sizeOf() >= size, InstructionBuilderArgsLengthMismatch()); }
    }

    /// @notice Count items of a variable-length instruction
    /// @dev Require `args` to be exactly `headSize` bytes followed by one or more whole `itemSize`-byte items
    ///   Both sizes are relative to `args`, header excluded
    function itemsCount(bytes calldata args, uint256 headSize, uint256 itemSize) internal pure returns (uint256 count) {
        unchecked {
            require(args.length >= headSize + itemSize, InstructionBuilderArgsLengthMismatch());
            uint256 itemsSize = args.length - headSize;
            count = itemsSize / itemSize;
            require(count * itemSize == itemsSize, InstructionBuilderArgsLengthMismatch());
        }
    }

    function pushHeader(MemoryPtr ptr, Opcode opcode) internal pure returns (MemoryPtr) {
        return ptr.push(opcode.asU8()).skip(1);
    }

    function patchLength(MemoryPtr ptr, MemoryPtr end) internal pure {
        uint256 length = end.sub(ptr) - sizeOf();
        require(length < 256, InstructionBuilderArgsLengthExceeded(length));
        ptr.skip(1).patch(uint8(length));
    }

    function encodeBool(bool value, uint8 bit) internal pure returns (uint8 res) {
        require(bit < 8, InstructionBuilderBitExceedsByte(bit));
        if (value) res = uint8(128 >> bit);
    }
}
