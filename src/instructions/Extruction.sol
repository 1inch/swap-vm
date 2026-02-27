// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib, SwapQuery, SwapRegisters } from "../libs/VM.sol";

/// @title IExtruction - State-modifying external logic interface
/// @notice Interface for external contracts that implement custom swap logic during swap() execution
/// @dev CRITICAL SECURITY REQUIREMENTS:
///      - Implementations MUST produce deterministic and consistent results with IStaticExtruction
///      - The same inputs MUST yield the same swap amounts in both interfaces
///      - Non-deterministic behavior will cause quote/swap inconsistencies and unexpected execution
///      - Target contracts SHOULD be immutable (non-upgradeable) to prevent logic changes between quote/swap
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

/// @title IStaticExtruction - View-only external logic interface
/// @notice Interface for external contracts that implement custom swap logic during quote() execution
/// @dev CRITICAL SECURITY REQUIREMENTS:
///      - Implementations MUST be deterministic and consistent with IExtruction
///      - The same inputs MUST yield the same swap amounts in both interfaces
///      - This is the read-only version called during quoting operations
///      - Inconsistent implementations will break quote/swap consistency guarantees
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

/// @title Extruction - External Custom Logic Delegation
/// @notice Allows makers to delegate pricing and state logic to external contracts for advanced strategies
/// @dev IMPORTANT SECURITY CONSIDERATIONS FOR TAKERS/RESOLVERS:
///
///      Quote/Swap Consistency Risk:
///      - This instruction delegates logic to maker-controlled external contracts
///      - Takers MUST validate strategy consistency before execution
///      - IStaticExtruction.extruction() (quote) and IExtruction.extruction() (swap) MUST return
///        consistent results for the same inputs
///
///      Validation Requirements:
///      - Verify target contract is non-upgradeable or has trusted governance
///      - Ensure target implementation is deterministic and cannot change between quote/swap
///      - Review target contract code for correctness and security
///      - Test quote/swap consistency before routing significant volume
///
///      Risk Mitigation:
///      - Takers already have slippage protection via threshold amounts
///      - Consider using additional monitoring for Extruction-based strategies
///      - Only interact with strategies that have been thoroughly validated
///
///      This is a "use at your own risk" feature designed for advanced use cases.
///      Failure to validate may result in quote/swap inconsistencies, reverts, or unexpected execution.
contract Extruction {
    using Calldata for bytes;
    using ContextLib for Context;

    error ExtructionMissingTargetArg();
    error ExtructionChoppedExceededLength(bytes chopped, uint256 requested);

    /// @dev Calls an external contract to perform custom logic, potentially modifying the swap state
    /// @dev QUOTE/SWAP DIVERGENCE: This instruction delegates to external contracts (IStaticExtruction for
    ///   quote, IExtruction for swap). Target implementations MUST be deterministic and return consistent
    ///   results in both modes. Non-deterministic behavior breaks numerical consistency. Makers MUST NOT
    ///   use backward jumps to this instruction as it breaks consistency between quote() and swap().
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
