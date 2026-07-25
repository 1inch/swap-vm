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

    /// @notice Emitted when the protocol fee could not be collected and the swap proceeded without it
    /// @param orderHash Strategy the fee was charged against
    /// @param token The tokenIn the fee was denominated in
    /// @param to Recipient that was not paid
    /// @param amount Fee amount that was not collected
    event ProtocolFeeSkipped(bytes32 orderHash, address token, address to, uint256 amount);

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

    /// @notice Protocol fee on amountIn — transfers fee from maker to recipient via transferFrom.
    /// @dev The fee is charged during program execution (inside runLoop), which is before SwapVM completes
    ///   the taker→maker tokenIn transfer, so it comes out of tokenIn the maker already holds. A maker
    ///   short of tokenIn balance or allowance does not pay the fee and the swap proceeds without it,
    ///   which is reported through ProtocolFeeSkipped.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the actual token transfer. Makers MUST NOT use backward jumps to this instruction as it
    ///   may break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _tryTransferFee(ctx, to, feeAmountIn);
        }
    }

    /// @notice Protocol fee on amountIn for Aqua — pulls fee from maker's Aqua balance to recipient.
    /// @dev The fee pull happens during program execution (inside runLoop), which is before SwapVM completes
    ///   the taker→maker tokenIn transfer, so it comes out of the maker's existing Aqua tokenIn balance. A
    ///   maker whose balance is short of the fee does not pay it and the swap proceeds without it, which is
    ///   reported through ProtocolFeeSkipped.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the Aqua pull operation. Makers MUST NOT use backward jumps to this instruction as it may
    ///   break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _tryPullFee(ctx, to, feeAmountIn);
        }
    }

    /// @notice Dynamic protocol fee with external fee provider
    /// @dev IMPORTANT: The maker MUST already hold sufficient tokenIn balance and have approved this contract
    ///   BEFORE the swap is executed. The fee transfer occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the maker lacks tokenIn
    ///   balance or allowance, the swap will revert.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the actual token transfer. Quote may succeed while swap reverts due to insufficient
    ///   balance or missing approval. Makers MUST NOT use backward jumps to this instruction as it may
    ///   break numerical consistency between quote() and swap().
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

            if (!ctx.vm.isStaticContext && feeAmountIn > 0) {
                _tryTransferFee(ctx, to, feeAmountIn);
            }
        }
    }

    /// @notice Dynamic protocol fee with external fee provider (Aqua version)
    /// @dev IMPORTANT: The maker MUST already hold sufficient tokenIn balance in Aqua BEFORE the swap
    ///   is executed. The fee pull occurs during program execution (inside runLoop), which is before
    ///   SwapVM completes the taker→maker tokenIn transfer. If the maker's Aqua tokenIn balance is
    ///   insufficient, the swap will revert.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the Aqua pull operation. Quote may succeed while swap reverts due to insufficient
    ///   Aqua balance. Makers MUST NOT use backward jumps to this instruction as it may break numerical
    ///   consistency between quote() and swap().
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

            if (!ctx.vm.isStaticContext && feeAmountIn > 0) {
                _tryPullFee(ctx, to, feeAmountIn);
            }
        }
    }

    // Internal functions

    /// @dev Pulls the fee from the maker's Aqua balance. amountNetPulled is only credited when the pull
    ///      lands, so a skipped fee leaves the taker owing the full amountIn.
    function _tryPullFee(Context memory ctx, address to, uint256 feeAmountIn) private {
        try _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to) {
            ctx.swap.amountNetPulled += feeAmountIn;
        } catch {
            emit ProtocolFeeSkipped(ctx.query.orderHash, ctx.query.tokenIn, to, feeAmountIn);
        }
    }

    /// @dev Charges the fee against the maker's wallet, applying the same success rules as SafeERC20 but
    ///      reporting failure through an event instead of reverting.
    function _tryTransferFee(Context memory ctx, address to, uint256 feeAmountIn) private {
        address token = ctx.query.tokenIn;
        address from = ctx.query.maker;
        bytes4 selector = IERC20.transferFrom.selector;
        bool success;
        assembly ("memory-safe") {
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), feeAmountIn)
            success := call(gas(), token, 0, data, 0x64, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 {
                    success := gt(extcodesize(token), 0)
                }
                default {
                    success := and(gt(returndatasize(), 31), eq(mload(0), 1))
                }
            }
        }

        if (!success) emit ProtocolFeeSkipped(ctx.query.orderHash, token, to, feeAmountIn);
    }

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
