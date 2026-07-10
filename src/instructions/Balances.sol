// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice StaticBalances opcode, set context token balances to specified values
/// @dev Encoding: [uint256 balanceA, uint256 balanceB]
library StaticBalances {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    Opcode constant opcode = Opcode.StaticBalances;

    function build(uint256 balanceA, uint256 balanceB) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(balanceA, balanceB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint256 balanceA, uint256 balanceB) {
        balanceA = args.at(0).asU256();
        balanceB = args.at(32).asU256();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 balanceIn;
        uint256 balanceOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = parse(args);
        else (balanceOut, balanceIn) = parse(args);

        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
    }
}

/// @notice DynamicBalances opcode, set context token balances to storage values, initialized with specified values
/// @dev Encoding: [uint256 balanceA, uint256 balanceB]
/// @dev In quote mode reads storage but does not update it
/// @dev The opcode is expected to be executed only once in strategy flow, multiple inclusions may lead to unexpected balances stored
library DynamicBalances {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    error DynamicBalancesReachZero();

    Opcode constant opcode = Opcode.DynamicBalances;

    function build(uint256 balanceA, uint256 balanceB) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(balanceA, balanceB);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint256 balanceA, uint256 balanceB) {
        balanceA = args.at(0).asU256();
        balanceB = args.at(32).asU256();
    }

    struct Storage {
        mapping(bytes32 orderHash => mapping(address token => uint256)) balance;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("1inch.storage.DynamicBalances")) - 1)) & ~bytes32(uint256(0xff));
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();

        uint256 balanceIn = $.balance[ctx.query.orderHash][ctx.query.tokenIn];
        uint256 balanceOut = $.balance[ctx.query.orderHash][ctx.query.tokenOut];

        if (balanceIn | balanceOut == 0) {
            if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = parse(args);
            else (balanceOut, balanceIn) = parse(args);
        }

        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;

        ctx.runLoop();

        balanceIn += ctx.swap.amountIn;
        balanceOut -= ctx.swap.amountOut;

        if (!ctx.vm.isStaticContext) {
            require(balanceIn | balanceOut != 0, DynamicBalancesReachZero());
            $.balance[ctx.query.orderHash][ctx.query.tokenIn] = balanceIn;
            $.balance[ctx.query.orderHash][ctx.query.tokenOut] = balanceOut;
        }
    }
}

contract DynamicBalancesExternal {
    function balance(bytes32 orderHash, address token) external view returns (uint256) {
        DynamicBalances.Storage storage $ = DynamicBalances.store();
        return $.balance[orderHash][token];
    }
}
