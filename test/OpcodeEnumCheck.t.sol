// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Opcode } from "../src/libs/Opcodes.sol";

contract OpcodeEnumCheckTest is Test {
    function test_EnumValuesMatchHexLabels() public pure {
        assertEq(uint8(Opcode.Stop), 0x00);
        assertEq(uint8(Opcode.Extruction), 0x04);
        assertEq(uint8(Opcode._fe), 0xfe);
        assertEq(uint8(Opcode._ff), 0xff);
    }
}
