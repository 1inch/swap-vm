// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Opcode } from "../src/libs/OpcodeList.sol";

contract OpcodeEnumCheckTest is Test {
    function test_EnumValuesMatchHexLabels() public pure {
        // Core control flow bank (0x00-0x0f)
        assertEq(uint8(Opcode.Stop), 0x00);
        assertEq(uint8(Opcode.Extruction), 0x04);
        // Debug bank (0x10-0x1f)
        assertEq(uint8(Opcode.PrintSwapRegisters), 0x10);
        assertEq(uint8(Opcode.PatchSwapRegisters), 0x1a);
        // Conditions & access guards bank (0x20-0x3f)
        assertEq(uint8(Opcode.Deadline), 0x20);
        assertEq(uint8(Opcode.WhitelistSequential), 0x2d);
        assertEq(uint8(Opcode.JumpIfDirection), 0x30);
        // Invalidators & epochs bank (0x40-0x4f)
        assertEq(uint8(Opcode.InvalidateBit), 0x40);
        assertEq(uint8(Opcode.ValidateSeriesEpoch), 0x48);
        // Swap curves bank (0x50-0x6f)
        assertEq(uint8(Opcode.XYCSwap), 0x50);
        assertEq(uint8(Opcode.PeggedSwap), 0x58);
        // Fees bank (0x70-0x8f)
        assertEq(uint8(Opcode.FeeFlatIn), 0x70);
        assertEq(uint8(Opcode.FeeFlatOut), 0x71);
        assertEq(uint8(Opcode.FeeProgressiveIn), 0x72);
        assertEq(uint8(Opcode.FeeProgressiveOut), 0x73);
        assertEq(uint8(Opcode.FeeProtocol), 0x80);
        // Balances tuning bank (0x90-0xaf)
        assertEq(uint8(Opcode.StaticBalances), 0x90);
        assertEq(uint8(Opcode.PiecewiseLinearScaleBalanceIn), 0x98);
        assertEq(uint8(Opcode.Decay), 0x9c);
        assertEq(uint8(Opcode.TWAPSwap), 0x9d);
        // Rates tuning bank (0xb0-0xcf)
        assertEq(uint8(Opcode.RequireMinRate), 0xb0);
        assertEq(uint8(Opcode.BaseFeeAdjuster), 0xb4);
        // Reserved bank tail (0xf0-0xff)
        assertEq(uint8(Opcode._fe), 0xfe);
        assertEq(uint8(Opcode._ff), 0xff);
    }
}
