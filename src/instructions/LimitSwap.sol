// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library LimitSwapArgsBuilder {
    using Calldata for bytes;

    error LimitSwapArgsBuilderMissingMakerDirectionLt();

    function build(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn < tokenOut);
    }

    function parse(bytes calldata args) internal pure returns (bool makerDirectionLt) {
        makerDirectionLt = uint8(bytes1(args.slice(0, 1, LimitSwapArgsBuilderMissingMakerDirectionLt.selector))) != 0;
    }
}

/// @dev Use with Balances._setBalance() instruction to ensure both balances are non-zero before proceeding with swap.
contract LimitSwap {
    using Math for uint256;
    using ContextLib for Context;

    error LimitSwapDirectionMismatch();
    error LimitSwapRecomputeDetected();
    error LimitSwapRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);
    error LimitSwapFullyRequiresAmountInToMatchBalanceIn(uint256 amountIn, uint256 balanceIn);
    error LimitSwapFullyRequiresAmountOutToMatchBalanceOut(uint256 amountOut, uint256 balanceOut);

    /// @param args.makerDirectionLt | 1 byte (boolean, true if tokenIn < tokenOut)
    function _limitSwap1D(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, LimitSwapRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut));

        bool makerDirectionLt = LimitSwapArgsBuilder.parse(args);
        bool takerDirectionLt = ctx.query.tokenIn < ctx.query.tokenOut;
        require(makerDirectionLt == takerDirectionLt, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, LimitSwapRecomputeDetected());
            ctx.swap.amountOut = ctx.swap.amountIn * ctx.swap.balanceOut / ctx.swap.balanceIn; // Floor division for tokenOut is desired behavior
        } else {
            require(ctx.swap.amountIn == 0, LimitSwapRecomputeDetected());
            ctx.swap.amountIn = (ctx.swap.amountOut * ctx.swap.balanceIn).ceilDiv(ctx.swap.balanceOut); // Ceiling division for tokenIn is desired behavior
        }
    }

    /// @param args.makerDirectionLt | 1 byte (boolean, true if tokenIn < tokenOut)
    function _limitSwapOnlyFull1D(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, LimitSwapRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut));

        bool makerDirectionLt = LimitSwapArgsBuilder.parse(args);
        bool takerDirectionLt = ctx.query.tokenIn < ctx.query.tokenOut;
        require(makerDirectionLt == takerDirectionLt, LimitSwapDirectionMismatch());

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountIn == ctx.swap.balanceIn, LimitSwapFullyRequiresAmountInToMatchBalanceIn(ctx.swap.amountIn, ctx.swap.balanceIn));
            require(ctx.swap.amountOut == 0, LimitSwapRecomputeDetected());
            ctx.swap.amountOut = ctx.swap.balanceOut;
        } else {
            require(ctx.swap.amountOut == ctx.swap.balanceOut, LimitSwapFullyRequiresAmountOutToMatchBalanceOut(ctx.swap.amountOut, ctx.swap.balanceOut));
            require(ctx.swap.amountIn == 0, LimitSwapRecomputeDetected());
            ctx.swap.amountIn = ctx.swap.balanceIn;
        }
    }
}
