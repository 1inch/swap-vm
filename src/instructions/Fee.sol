// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { IProtocolFeeProvider } from "./interfaces/IProtocolFeeProvider.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;

library FeeArgsBuilder {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);

    function buildFlatFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function buildProtocolFee(uint32 feeBps, address to) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps, to);
    }

    function buildDynamicProtocolFee(address feeProvider) internal pure returns (bytes memory) {
        return abi.encodePacked(feeProvider);
    }

    function parseFlatFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args));
    }

    function parseProtocolFee(bytes calldata args) internal pure returns (uint32 feeBps, address to) {
        feeBps = uint32(bytes4(args));
        to = address(uint160(bytes20(args.slice(4))));
    }

    function parseDynamicProtocolFee(bytes calldata args) internal pure returns (address feeProvider) {
        feeProvider = address(uint160(bytes20(args)));
    }
}

contract Fee {
    using SafeERC20 for IERC20;
    using ContextLib for Context;

    error FeeShouldBeAppliedBeforeSwapAmountsComputation();
    error FeeDynamicProtocolInvalidRecipient();
    error FeeBpsOutOfRange(uint256 feeBps);
    error FeeProtocolProviderFailedCall();

    IAqua internal immutable _AQUA;

    constructor(address aqua) {
        _AQUA = IAqua(aqua);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        // This is the same _feeAmountIn call, just with rounding up.
        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            ctx.swap.amountIn -= Math.ceilDiv(ctx.swap.amountIn * feeBps, BPS);
            ctx.runLoop();
            ctx.swap.amountIn += Math.ceilDiv(ctx.swap.amountIn * feeBps, BPS - feeBps);
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            ctx.swap.amountIn += Math.ceilDiv(ctx.swap.amountIn * feeBps, BPS - feeBps);
        }
    }

    /// @notice Protocol fee on amountIn — charges the maker's wallet via safeTransferFrom.
    /// @dev The fee is accrued on the context and settled by SwapVM after the transfer phase, so it is
    ///   payable out of the tokenIn the taker delivers. A maker whose tokenIn is routed to a custom
    ///   receiver or unwrapped to native coin still has to hold tokenIn and approve this contract.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but accrues nothing. Quote may succeed while swap reverts due to a missing approval. Makers MUST
    ///   NOT use backward jumps to this instruction as it may break numerical consistency between quote()
    ///   and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            ctx.accrueFee(to, false, feeAmountIn);
        }
    }

    /// @notice Protocol fee on amountIn for Aqua — pulls fee from maker's Aqua balance to recipient.
    /// @dev The fee is accrued on the context and settled by SwapVM after the transfer phase, once the
    ///   taker's tokenIn has landed in the maker's Aqua balance. The maker does not need any pre-existing
    ///   tokenIn balance, which is what makes single-sided positions tradable.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but accrues nothing. Makers MUST NOT use backward jumps to this instruction as it may break
    ///   numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            ctx.accrueFee(to, true, feeAmountIn);
        }
    }

    /// @notice Dynamic protocol fee with external fee provider
    /// @dev The fee is accrued on the context and settled by SwapVM after the transfer phase, so it is
    ///   payable out of the tokenIn the taker delivers. A maker whose tokenIn is routed to a custom
    ///   receiver or unwrapped to native coin still has to hold tokenIn and approve this contract.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but accrues nothing. Quote may succeed while swap reverts due to a missing approval. Makers MUST
    ///   NOT use backward jumps to this instruction as it may break numerical consistency between quote()
    ///   and swap().
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLockUnsafe on orderHash level in SwapVM.swap()
    ///   - Fee calculation and state changes happen AFTER external call
    ///   - feeProvider MUST NOT rely on intermediate swap state
    ///   CAUTION: Takers should verify feeProvider trustworthiness before executing.
    ///      A malicious feeProvider could return large data causing high gas consumption.
    /// @param args.feeProvider | 20 bytes (address of the protocol fee provider)
    function _dynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        address feeProvider = FeeArgsBuilder.parseDynamicProtocolFee(args);
        uint256 feeBps;
        address to;

        if (feeProvider != address(0)) {
            (bool success, bytes memory result) = feeProvider.staticcall(abi.encodeCall(
                IProtocolFeeProvider.getFeeBpsAndRecipient,
                (ctx.query.orderHash,
                ctx.query.maker,
                ctx.query.taker,
                ctx.query.tokenIn,
                ctx.query.tokenOut,
                ctx.query.isExactIn)
            ));

            require(success && result.length == 64, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext) {
                ctx.accrueFee(to, false, feeAmountIn);
            }
        }
    }

    /// @notice Dynamic protocol fee with external fee provider (Aqua version)
    /// @dev The fee is accrued on the context and settled by SwapVM after the transfer phase, once the
    ///   taker's tokenIn has landed in the maker's Aqua balance. The maker does not need any pre-existing
    ///   tokenIn balance, which is what makes single-sided positions tradable.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but accrues nothing. Makers MUST NOT use backward jumps to this instruction as it may break
    ///   numerical consistency between quote() and swap().
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLockUnsafe on orderHash level in SwapVM.swap()
    ///   - Fee calculation and state changes happen AFTER external call
    ///   - feeProvider MUST NOT rely on intermediate swap state
    ///   CAUTION: Takers should verify feeProvider trustworthiness before executing.
    ///      A malicious feeProvider could return large data causing high gas consumption.
    /// @param args.feeProvider | 20 bytes (address of the protocol fee provider)
    function _aquaDynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        address feeProvider = FeeArgsBuilder.parseDynamicProtocolFee(args);
        uint256 feeBps;
        address to;

        if (feeProvider != address(0)) {
            (bool success, bytes memory result) = feeProvider.staticcall(abi.encodeCall(
                IProtocolFeeProvider.getFeeBpsAndRecipient,
                (ctx.query.orderHash,
                ctx.query.maker,
                ctx.query.taker,
                ctx.query.tokenIn,
                ctx.query.tokenOut,
                ctx.query.isExactIn)
            ));

            require(success && result.length == 64, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext) {
                ctx.accrueFee(to, true, feeAmountIn);
            }
        }
    }

    // Internal functions

    function _feeAmountIn(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
            ctx.swap.amountIn -= feeAmountIn;
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
        }
    }
}
