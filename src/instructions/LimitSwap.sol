// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice LimitSwap opcode, linear swap in specified direction
/// @dev Encoding: [bool direction]
library LimitSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Math for uint256;

    error LimitSwapDirectionMismatch();

    Opcode constant opcode = Opcode.LimitSwap;

    function build(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(InstructionBuilder.encodeBool(tokenIn < tokenOut, 0));
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (bool direction) {
        direction = args.at(0).asBool(0);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        bool direction = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        require(direction == swapDirection, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            // Floor division for tokenOut favors maker
            ctx.swap.amountOut = ctx.swap.amountIn * ctx.swap.balanceOut / ctx.swap.balanceIn;
        } else {
            // Ceil division for tokenIn favors maker
            ctx.swap.amountIn = (ctx.swap.amountOut * ctx.swap.balanceIn).ceilDiv(ctx.swap.balanceOut);
        }
    }
}

/// @notice LimitSwapFullAmount opcode, swap balanceIn for balanceOut in specified direction
/// @dev Encoding: [bool direction]
library LimitSwapFullAmount {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error LimitSwapDirectionMismatch();
    error LimitSwapAmountShouldMatchBalance(uint256 amount, uint256 balance);

    Opcode constant opcode = Opcode.LimitSwapFullAmount;

    function build(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(InstructionBuilder.encodeBool(tokenIn < tokenOut, 0));
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (bool direction) {
        direction = args.at(0).asBool(0);
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        bool direction = parse(args);
        bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
        require(direction == swapDirection, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountIn == ctx.swap.balanceIn, LimitSwapAmountShouldMatchBalance(ctx.swap.amountIn, ctx.swap.balanceIn));
            ctx.swap.amountOut = ctx.swap.balanceOut;
        } else {
            require(ctx.swap.amountOut == ctx.swap.balanceOut, LimitSwapAmountShouldMatchBalance(ctx.swap.amountOut, ctx.swap.balanceOut));
            ctx.swap.amountIn = ctx.swap.balanceIn;
        }
    }
}
