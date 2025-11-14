// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Calldata } from "../libs/Calldata.sol";
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

contract Extruction {
    using Calldata for bytes;
    using ContextLib for Context;

    error ExtructionMissingTargetArg();
    error ExtructionChoppedExceededLength(bytes chopped, uint256 requested);

    /// @dev Calls an external contract to perform custom logic, potentially modifying the swap state
    /// @param args.target         | 20 bytes
    /// @param args.extructionArgs | N bytes
    function _extruction(Context memory ctx, bytes calldata args) internal {
        if (ctx.vm.isStaticContext) {
            _exctructionStatic(ctx, args);
        } else {
            _exctructionNonStatic(ctx, args);
        }
    }

    function _exctructionStatic(Context memory ctx, bytes calldata args) internal view {
        address target = address(uint160(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector))));
        uint256 choppedLength;
        (bool success, bytes memory data) = target.staticcall(
            abi.encodeWithSelector(
                IExtruction.extruction.selector,
                ctx.vm.isStaticContext,
                ctx.vm.nextPC,
                ctx.query,
                ctx.swap,
                args.slice(20),
                ctx.takerArgs()
            )
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        (ctx.vm.nextPC, choppedLength, ) = abi.decode(data, (uint256, uint256, SwapRegisters));
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength)); // Revert if not enough data
    }

    function _exctructionNonStatic(Context memory ctx, bytes calldata args) internal {
        address target = address(uint160(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector))));
        uint256 choppedLength;
        (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(
            ctx.vm.isStaticContext,
            ctx.vm.nextPC,
            ctx.query,
            ctx.swap,
            args.slice(20),
            ctx.takerArgs()
        );
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength)); // Revert if not enough data
    }
}
