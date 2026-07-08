// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Opcode, OpcodeOps } from "./OpcodeList.sol";

library InstructionBuilder {
    using OpcodeOps for Opcode;

    error InstructionBuilderArgsLengthExceeded(uint256 length);
    error InstructionBuilderBitExceedsByte(uint256 bit);

    function build(Opcode opcode, bytes memory args) internal pure returns (bytes memory) {
        require(args.length < 256, InstructionBuilderArgsLengthExceeded(args.length));
        return abi.encodePacked(opcode.asU8(), uint8(args.length), args);
    }

    function build(Opcode opcode) internal pure returns (bytes memory) {
        return build(opcode, "");
    }

    function encodeBool(bool value, uint8 bit) internal pure returns (uint8 res) {
        require(bit < 8, InstructionBuilderBitExceedsByte(bit));
        if (value) res = uint8(128 >> bit); 
    }
}
