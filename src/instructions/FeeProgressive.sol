// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice FeeProgressiveIn opcode, token in liquidity provider progressive percent fee
/// @dev Fee percentage increases with `amount / balance` fraction:
///   `fee = (feeBps * amount ** 2) / (balance + feeBps * amount)`
/// @dev Encoding: [uint24 feeBps]
library FeeProgressiveIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;
    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);

    Opcode constant opcode = Opcode.FeeProgressiveIn;

    uint256 constant BPS = 1e7;

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        require(feeBps < BPS, FeeBpsOutOfRange(feeBps));

        bytes memory args = abi.encodePacked(feeBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint24 feeBps) {
        feeBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint24 feeBps = parse(args);

        if (ctx.query.isExactIn) {
            uint256 fee = (feeBps * ctx.swap.amountIn ** 2).ceilDiv(BPS * ctx.swap.balanceIn + feeBps * ctx.swap.amountIn);

            ctx.swap.amountIn -= fee;
            ctx.runLoop();
            ctx.swap.amountIn += fee;
        } else {
            ctx.runLoop();

            uint256 fee = (feeBps * ctx.swap.amountIn ** 2).ceilDiv(BPS * ctx.swap.balanceIn - feeBps * ctx.swap.amountIn);
            ctx.swap.amountIn += fee;
        }
    }
}

/// @notice FeeProgressiveOut opcode, token out liquidity provider progressive percent fee
/// @dev Fee percentage increases with `amount / balance` fraction:
///   `fee = (feeBps * amount ** 2) / (balance + feeBps * amount)`
/// @dev Encoding: [uint24 feeBps]
/// @dev In combination with AMM auto-reinvesting curves may cause superadditive behavior
///   Fees are deposited against swap direction causing a price rollback effect `swap(a) + swap(b) > swap(c)`
library FeeProgressiveOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;
    using Math for uint256;

    error FeeBpsOutOfRange(uint24 feeBps);

    Opcode constant opcode = Opcode.FeeProgressiveOut;

    uint256 constant BPS = 1e7;

    function build(uint24 feeBps) internal pure returns (bytes memory) {
        require(feeBps < BPS, FeeBpsOutOfRange(feeBps));

        bytes memory args = abi.encodePacked(feeBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint24 feeBps) {
        feeBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        uint24 feeBps = parse(args);

        if (ctx.query.isExactIn) {
            ctx.runLoop();

            uint256 fee = (feeBps * ctx.swap.amountOut ** 2).ceilDiv(BPS * ctx.swap.balanceOut + feeBps * ctx.swap.amountOut);
            ctx.swap.amountOut -= fee;
        } else {
            uint256 fee = (feeBps * ctx.swap.amountOut ** 2).ceilDiv(BPS * ctx.swap.balanceOut - feeBps * ctx.swap.amountOut);

            ctx.swap.amountOut += fee;
            ctx.runLoop();
            ctx.swap.amountOut -= fee;
        }
    }
}
