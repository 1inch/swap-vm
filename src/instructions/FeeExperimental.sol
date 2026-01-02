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

import { Fee, FeeArgsBuilder, BPS } from "./Fee.sol";

library FeeArgsBuilderExperimental {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);
    error ProgressiveFeeMissingFeeBPS();

    function buildProgressiveFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function parseProgressiveFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProgressiveFeeMissingFeeBPS.selector)));
    }
}

contract FeeExperimental is Fee {
    using SafeERC20 for IERC20;
    using ContextLib for Context;

    constructor(address aqua) Fee(aqua) {}

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        _feeAmountOut(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (base fee in bps, 1e9 = 100%)
    function _progressiveFeeInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilderExperimental.parseProgressiveFee(args);

        if (ctx.query.isExactIn) {
            // Increase amountIn by fee only during swap-instruction
            // Formula: dx_eff = dx / (1 + λ * dx / x)
            // Rearranged for precision: dx_eff = (dx * BPS * x) / (BPS * x + λ * dx)
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            ctx.swap.amountIn = (
                (BPS * ctx.swap.amountIn * ctx.swap.balanceIn) /
                (BPS * ctx.swap.balanceIn + feeBps * ctx.swap.amountIn)
            );
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();

            // Increase amountIn by fee after swap-instruction
            // Formula: dx = dx_eff / (1 - λ * dx_eff / x)
            // Rearranged for precision: dx = (dx_eff * BPS * x) / (BPS * x - λ * dx_eff)
            ctx.swap.amountIn = Math.ceilDiv(
                (BPS * ctx.swap.amountIn * ctx.swap.balanceIn),
                (BPS * ctx.swap.balanceIn - feeBps * ctx.swap.amountIn)
            );
        }
    }

    /// @param args.feeBps | 4 bytes (base fee in bps, 1e9 = 100%)
    function _progressiveFeeOutXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilderExperimental.parseProgressiveFee(args);

        if (ctx.query.isExactIn) {
            ctx.runLoop();

            // Decrease amountOut by fee after swap-instruction
            // Formula: dy_eff = dy / (1 + λ * dy / y)
            // Rearranged for precision: dy_eff = (dy * BPS * y) / (BPS * y + λ * dy)
            ctx.swap.amountOut = (
                (BPS * ctx.swap.amountOut * ctx.swap.balanceOut) /
                (BPS * ctx.swap.balanceOut + feeBps * ctx.swap.amountOut)
            );
        } else {
            // Decrease amountOut by fee only during swap-instruction
            // Formula: dy = dy_eff / (1 - λ * dy_eff / y)
            // Rearranged for precision: dy = (dy_eff * BPS * y) / (BPS * y - λ * dy_eff)
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            ctx.swap.amountOut = Math.ceilDiv(
                (BPS * ctx.swap.amountOut * ctx.swap.balanceOut),
                (BPS * ctx.swap.balanceOut - feeBps * ctx.swap.amountOut)
            );
            ctx.runLoop();
            ctx.swap.amountOut = takerDefinedAmountOut;
        }
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountOut = _feeAmountOut(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            IERC20(ctx.query.tokenOut).safeTransferFrom(ctx.query.maker, to, feeAmountOut);
        }
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountOut = _feeAmountOut(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenOut, feeAmountOut, to);
        }
    }

    // Internal functions

    function _feeAmountOut(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountOut) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountOut by fee after passing to swap-instruction
            ctx.runLoop();
            feeAmountOut = ctx.swap.amountOut * feeBps / BPS;
            ctx.swap.amountOut -= feeAmountOut;
        } else {
            // Increase amountOut by fee only during swap-instruction
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            feeAmountOut = ctx.swap.amountOut * feeBps / (BPS - feeBps);
            ctx.swap.amountOut += feeAmountOut;
            ctx.runLoop();
            ctx.swap.amountOut = takerDefinedAmountOut;
        }
    }
}
