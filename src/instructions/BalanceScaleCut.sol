// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice BalanceScaleCutIn opcode, maker-favor balances rate guard
/// @dev Encoding: [uint64 rateA, uint64 rateB]
/// @dev Supports only single direction swaps
/// @dev Should be placed after balance in adjustment opcodes and before the swap opcode
library BalanceScaleCutIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Math for uint256;

    error BalanceScaleCutRateZero();

    Opcode constant opcode = Opcode.BalanceScaleCutIn;

    function build(uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        require(rateA > 0 && rateB > 0, BalanceScaleCutRateZero());

        bytes memory args = abi.encodePacked(rateA, rateB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 rateA, uint64 rateB) {
        rateA = args.at(0).asU64();
        rateB = args.at(8).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint64 rateIn;
        uint64 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (rateIn, rateOut) = parse(args);
        else (rateOut, rateIn) = parse(args);

        // Ceil division for the balance-in floor favors maker
        uint256 minBalanceIn = (ctx.swap.balanceOut * rateIn).ceilDiv(rateOut);
        if (ctx.swap.balanceIn < minBalanceIn) {
            ctx.swap.balanceIn = minBalanceIn;
        }
    }
}

/// @notice BalanceScaleCutOut opcode, maker-favor balances rate guard
/// @dev Encoding: [uint64 rateA, uint64 rateB]
/// @dev Supports only single direction swaps
/// @dev Should be placed after balance out adjustment opcodes and before the swap opcode
library BalanceScaleCutOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error BalanceScaleCutRateZero();

    Opcode constant opcode = Opcode.BalanceScaleCutOut;

    function build(uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        require(rateA > 0 && rateB > 0, BalanceScaleCutRateZero());

        bytes memory args = abi.encodePacked(rateA, rateB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 rateA, uint64 rateB) {
        rateA = args.at(0).asU64();
        rateB = args.at(8).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint64 rateIn;
        uint64 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (rateIn, rateOut) = parse(args);
        else (rateOut, rateIn) = parse(args);

        // Floor division for the balance-out cap favors maker
        uint256 maxBalanceOut = ctx.swap.balanceIn * rateOut / rateIn;
        if (ctx.swap.balanceOut > maxBalanceOut) {
            ctx.swap.balanceOut = maxBalanceOut;
        }
    }
}
