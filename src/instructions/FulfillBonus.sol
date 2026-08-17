// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice FulfillBonusBalanceIn opcode, taker bonus for order fulfillment
/// @dev Encoding: [uint24 incentiveBps]
/// @dev Supports only single direction swaps
/// @dev Should be placed after InvalidateTokenOut opcode
library FulfillBonusBalanceIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error FulfillBonusIncentiveOutOfRange(uint24 incentiveBps);

    Opcode constant opcode = Opcode.FulfillBonusBalanceIn;

    uint256 constant BPS = 1e7;

    function build(uint24 incentiveBps) internal pure returns (bytes memory) {
        require(incentiveBps < BPS, FulfillBonusIncentiveOutOfRange(incentiveBps));

        bytes memory args = abi.encodePacked(incentiveBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint24 incentiveBps) {
        incentiveBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (uint24 incentiveBps) = parse(args);

        uint256 scaled = ctx.swap.balanceIn * incentiveBps / BPS;
        if (
            ctx.query.isExactIn && ctx.swap.amountIn >= ctx.swap.balanceIn - scaled || 
            !ctx.query.isExactIn && ctx.swap.amountOut >= ctx.swap.balanceOut
        ) {
            ctx.swap.balanceIn -= scaled;
        }
    }
}

/// @notice FulfillBonusBalanceOut opcode, taker bonus for order fulfillment
/// @dev Encoding: [uint24 incentiveBps]
/// @dev Supports only single direction swaps
/// @dev Should be placed after InvalidateTokenIn opcode
library FulfillBonusBalanceOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error FulfillBonusIncentiveOutOfRange(uint24 incentiveBps);

    Opcode constant opcode = Opcode.FulfillBonusBalanceOut;

    uint256 constant BPS = 1e7;

    function build(uint24 incentiveBps) internal pure returns (bytes memory) {
        require(incentiveBps < BPS, FulfillBonusIncentiveOutOfRange(incentiveBps));

        bytes memory args = abi.encodePacked(incentiveBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint24 incentiveBps) {
        incentiveBps = args.at(0).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (uint24 incentiveBps) = parse(args);

        uint256 scaled = ctx.swap.balanceOut * incentiveBps / (BPS - incentiveBps);
        if (
            ctx.query.isExactIn && ctx.swap.amountIn >= ctx.swap.balanceIn || 
            !ctx.query.isExactIn && ctx.swap.amountOut >= ctx.swap.balanceOut + scaled
        ) {
            ctx.swap.balanceOut += scaled;
        }
    }
}
