// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { IProtocolFeeProvider } from "./interfaces/IProtocolFeeProvider.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;

library FeeArgsBuilder {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);
    error FeeMissingFeeBPS();
    error ProtocolFeeMissingFeeBPS();
    error ProtocolFeeMissingTo();
    error ProtocolFeeProviderMissingAddress();

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
        feeBps = uint32(bytes4(args.slice(0, 4, FeeMissingFeeBPS.selector)));
    }

    function parseProtocolFee(bytes calldata args) internal pure returns (uint32 feeBps, address to) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProtocolFeeMissingFeeBPS.selector)));
        to = address(uint160(bytes20(args.slice(4, 24, ProtocolFeeMissingTo.selector))));
    }

    function parseDynamicProtocolFee(bytes calldata args) internal pure returns (address feeProvider) {
        feeProvider = address(uint160(bytes20(args.slice(0, 20, ProtocolFeeProviderMissingAddress.selector))));
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
        _feeAmountIn(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            IERC20(ctx.query.tokenIn).safeTransferFrom(ctx.query.maker, to, feeAmountIn);
        }
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
        }
    }

    /// @notice Dynamic protocol fee with external fee provider
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLock on orderHash level in SwapVM.swap()
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

            require(success, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext) {
                IERC20(ctx.query.tokenIn).safeTransferFrom(ctx.query.maker, to, feeAmountIn);
            }
        }
    }

    /// @notice Dynamic protocol fee with external fee provider (Aqua version)
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLock on orderHash level in SwapVM.swap()
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

            require(success, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext) {
                _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
            }
        }
    }

    // Internal functions

    function _feeAmountIn(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
            ctx.swap.amountIn -= feeAmountIn;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
        }
    }
}
