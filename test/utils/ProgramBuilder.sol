// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "../../src/libs/VM.sol";
import { Opcode } from "../../src/libs/OpcodeList.sol";

type Program is uint256;

library ProgramBuilder {
    using SafeCast for uint256;

    function build(Program self, Opcode instruction) internal pure returns (bytes memory) {
        return build(self, instruction, "");
    }

    function build(Program, Opcode opcode, bytes memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(opcode, args.length.toUint8(), args);
    }
}
