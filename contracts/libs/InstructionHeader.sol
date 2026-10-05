// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Opcode } from "./OpcodeList.sol";
import { MemoryPtr } from "./MemoryPtr.sol";

/// @notice Instruction args builder helpers
/// @dev Encoding: [uint8 opcode, uint8 argsLength, bytes args], `args.length == argsLength`
library InstructionHeader {
    error InstructionHeaderArgsLengthExceeded(uint256 length);
    error InstructionHeaderArgsLengthMismatch();

    function sizeOf() internal pure returns (uint256) {
        return 2;
    }

    function pushHeader(MemoryPtr ptr, Opcode opcode) internal pure returns (MemoryPtr) {
        return ptr.push(opcode.asU8()).skip(1);
    }

    function patchLength(MemoryPtr ptr, MemoryPtr end) internal pure {
        uint256 length = end.sub(ptr) - sizeOf();
        require(length < 256, InstructionHeaderArgsLengthExceeded(length));
        ptr.skip(1).patch(uint8(length));
    }

    function exactLength(uint256 size, bytes calldata args) internal pure {
        // Believe `size` is `Opcode.sizeOf()` which includes `InstructionHeader.sizeof()`
        unchecked { require(size - sizeOf() == args.length, InstructionHeaderArgsLengthMismatch()); }
    }
}
