// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Opcode } from "./OpcodeList.sol";
import { MemoryPtr } from "./MemoryPtr.sol";

library InstructionBuilder {
    error InstructionBuilderArgsLengthExceeded(uint256 length);
    error InstructionBuilderBitExceedsByte(uint256 bit);

    function sizeOf() internal pure returns (uint256) {
        return 2;
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
