// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { Context, ContextLib, SwapQuery, SwapRegisters } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Extruction opcode, delegates swap registers to an external maker-chosen contract
///   The target may modify the swap registers, set the program counter and consume taker args
/// @dev Encoding: [address target, bytes extructionArgs]
/// @dev The extruction target is expected to be deterministic, consistent across quote / swap modes, calculations are
///   expected to be overflow-safe, revert conditions should be transparent, centralization and upgradability avoided
/// @dev General safety measures:
///   Maker min exchange rate expectations should be guarded by using RequireMinRate or AdjustMinRate before Extruction
///   Maker max spend expectations should be guarded by using AQUA or DynamicBalances for AMM-strategies
///   or using StaticBalances with InvalidateTokenIn or InvalidateTokenOut before Extruction for amount-limited strategies
///
///   Taker should employ threshold to guard the min exchange rate
///   SwapVM guards taker-specified amount to be unchanged by the strategy execution
/// @dev Execution of the opcode multiple times in strategy flow may lead to quote / swap divergence:
///   In swap mode extruction target may update storage affecting future executions while in quote mode storage could be only read
library Extruction {
    using Calldata for bytes;
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;

    error ExtructionChoppedExceedsLength(bytes chopped, uint256 requested);

    Opcode constant opcode = Opcode.Extruction;

    function build(address target, bytes memory extructionArgs) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(target, extructionArgs);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address target, bytes calldata extructionArgs) {
        target = args.at(0).asAddress();
        extructionArgs = args.slice(20);
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (address target, bytes calldata extructionArgs) = parse(args);
        uint256 choppedLength;

        if (ctx.vm.isStaticContext) {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                extructionArgs,
                ctx.takerArgs()
            );
        } else {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                extructionArgs,
                ctx.takerArgs()
            );
        }

        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceedsLength(chopped, choppedLength));
    }
}

interface IExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}

interface IStaticExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}
