// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice RequireMinRate opcode, maker-favor rate guard, fails if rate is worse than specified
///   Validates final amounts after rest of strategy executed
/// @dev Encoding: [uint64 rateA, uint64 rateB]
library RequireMinRate {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    error RequireMinRateFailed(uint256 amountIn, uint256 amountOut, uint256 rateIn, uint256 rateOut);

    Opcode constant opcode = Opcode.RequireMinRate;

    function build(uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(rateA, rateB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 rateA, uint64 rateB) {
        rateA = args.at(0).asU64();
        rateB = args.at(8).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint64 rateIn;
        uint64 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (rateIn, rateOut) = parse(args);
        else (rateOut, rateIn) = parse(args);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        // Cross-multiplication for: amountIn / amountOut >= rateIn / rateOut
        require(amountIn * rateOut >= rateIn * amountOut, RequireMinRateFailed(amountIn, amountOut, rateIn, rateOut));
    }
}

/// @notice AdjustMinRate opcode, maker-favor rate guard, patches amounts if rate is worse than specified
///   Validates and patches final amounts after rest of strategy executed
/// @dev Encoding: [uint64 rateA, uint64 rateB]
/// @dev Later opcodes in the execution sequence should consider the amounts are not final and might change
library AdjustMinRate {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;
    using Math for uint256;

    Opcode constant opcode = Opcode.AdjustMinRate;

    function build(uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(rateA, rateB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 rateA, uint64 rateB) {
        rateA = args.at(0).asU64();
        rateB = args.at(8).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint64 rateIn;
        uint64 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (rateIn, rateOut) = parse(args);
        else (rateOut, rateIn) = parse(args);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        // Cross-multiplication for: amountIn / amountOut < rateIn / rateOut
        if (amountIn * rateOut < rateIn * amountOut) {
            if (ctx.query.isExactIn) {
                // Floor division for tokenOut favors maker
                ctx.swap.amountOut = amountIn * rateOut / rateIn;
            } else {
                // Ceil division for tokenIn favors maker
                ctx.swap.amountIn = (amountOut * rateIn).ceilDiv(rateOut);
            }
        }
    }
}
