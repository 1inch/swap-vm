// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib, SwapQuery, SwapRegisters } from "../libs/VM.sol";

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

contract Extruction {
    using Calldata for bytes;
    using ContextLib for Context;

    error ExtructionMissingTargetArg();
    error ExtructionChoppedExceededLength(bytes chopped, uint256 requested);

    /// @dev Calls an external contract to perform custom logic, potentially modifying the swap state
    /// @param args.target         | 20 bytes
    /// @param args.extructionArgs | N bytes
    function _extruction(Context memory ctx, bytes calldata args) internal {
        address target = address(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector)));
        uint256 choppedLength;

        if (ctx.vm.isStaticContext) {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                args.slice(20),
                ctx.takerArgs()
            );
        } else {
            (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                args.slice(20),
                ctx.takerArgs()
            );
        }
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength)); // Revert if not enough data
    }
}
