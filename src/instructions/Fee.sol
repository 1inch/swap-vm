// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;

library FeeArgsBuilder {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);
    error FeeMissingFeeBPS();
    error ProtocolFeeMissingFeeBPS();
    error ProtocolFeeMissingTo();
    error ProgressiveFeeMissingFeeBPS();

    function buildFlatFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function buildProtocolFee(uint32 feeBps, address to) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps, to);
    }

    function buildProgressiveFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function parseFlatFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, FeeMissingFeeBPS.selector)));
    }

    function parseProtocolFee(bytes calldata args) internal pure returns (uint32 feeBps, address to) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProtocolFeeMissingFeeBPS.selector)));
        to = address(uint160(bytes20(args.slice(4, 24, ProtocolFeeMissingTo.selector))));
    }

    function parseProgressiveFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProgressiveFeeMissingFeeBPS.selector)));
    }

    error DepletionFeeMissingMinFeeBPS();
    error DepletionFeeMissingMaxFeeBPS();
    error DepletionFeeMissingReferenceBalanceIn();
    error DepletionFeeMissingReferenceBalanceOut();
    error DepletionFeeMinExceedsMax(uint32 minFeeBps, uint32 maxFeeBps);

    /// @notice Build args for depletion-based fee (enforces additivity and symmetry)
    /// @param minFeeBps Minimum fee rate (1e9 = 100%) - floor for restoring swaps
    /// @param maxFeeBps Maximum fee rate (1e9 = 100%) - cap for depleting swaps
    /// @param referenceBalanceIn Initial input reserve (X₀) - defines the initial ratio
    /// @param referenceBalanceOut Initial output reserve (Y₀) - defines the initial ratio
    function buildDepletionFee(uint32 minFeeBps, uint32 maxFeeBps, uint256 referenceBalanceIn, uint256 referenceBalanceOut) internal pure returns (bytes memory) {
        require(minFeeBps <= BPS, FeeBpsOutOfRange(minFeeBps));
        require(maxFeeBps <= BPS, FeeBpsOutOfRange(maxFeeBps));
        require(minFeeBps <= maxFeeBps, DepletionFeeMinExceedsMax(minFeeBps, maxFeeBps));
        return abi.encodePacked(minFeeBps, maxFeeBps, referenceBalanceIn, referenceBalanceOut);
    }

    function parseDepletionFee(bytes calldata args) internal pure returns (uint32 minFeeBps, uint32 maxFeeBps, uint256 referenceBalanceIn, uint256 referenceBalanceOut) {
        minFeeBps = uint32(bytes4(args.slice(0, 4, DepletionFeeMissingMinFeeBPS.selector)));
        maxFeeBps = uint32(bytes4(args.slice(4, 8, DepletionFeeMissingMaxFeeBPS.selector)));
        referenceBalanceIn = uint256(bytes32(args.slice(8, 40, DepletionFeeMissingReferenceBalanceIn.selector)));
        referenceBalanceOut = uint256(bytes32(args.slice(40, 72, DepletionFeeMissingReferenceBalanceOut.selector)));
    }
}

contract Fee {
    using SafeERC20 for IERC20;
    using ContextLib for Context;

    error FeeShouldBeAppliedBeforeSwapAmountsComputation();

    IAqua private immutable _AQUA;

    constructor(address aqua) {
        _AQUA = IAqua(aqua);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        _feeAmountIn(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        _feeAmountOut(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (base fee in bps, 1e9 = 100%)
    function _progressiveFeeInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseProgressiveFee(args);

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
        uint256 feeBps = FeeArgsBuilder.parseProgressiveFee(args);

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

    /// @notice Depletion fee on input - adjusts fee based on pool imbalance direction
    /// @dev Fee increases when swap moves pool away from initial ratio (depletion)
    /// @dev Fee decreases when swap moves pool toward initial ratio (restoration)
    /// @param args.minFeeBps | 4 bytes (minimum fee rate in bps, 1e9 = 100%)
    /// @param args.maxFeeBps | 4 bytes (maximum fee rate in bps, 1e9 = 100%)
    /// @param args.referenceBalanceIn | 32 bytes (X₀ - initial virtual input reserve)
    /// @param args.referenceBalanceOut | 32 bytes (Y₀ - initial virtual output reserve)
    function _depletionFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 minFeeBps, uint256 maxFeeBps, uint256 refBalanceIn, uint256 refBalanceOut) = FeeArgsBuilder.parseDepletionFee(args);

        if (ctx.query.isExactIn) {
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            uint256 feeAmount = _computeImbalanceFee(
                ctx.swap.amountIn,
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                refBalanceIn,
                refBalanceOut,
                minFeeBps,
                maxFeeBps
            );
            ctx.swap.amountIn -= feeAmount;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();
            ctx.swap.amountIn = _solveGrossForImbalanceFeeIn(
                ctx.swap.amountIn,
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                refBalanceIn,
                refBalanceOut,
                minFeeBps,
                maxFeeBps
            );
        }
    }

    /// @notice Depletion fee on output - adjusts fee based on pool imbalance direction
    /// @dev Fee increases when swap moves pool away from initial ratio (depletion)
    /// @dev Fee decreases when swap moves pool toward initial ratio (restoration)
    /// @param args.minFeeBps | 4 bytes (minimum fee rate in bps, 1e9 = 100%)
    /// @param args.maxFeeBps | 4 bytes (maximum fee rate in bps, 1e9 = 100%)
    /// @param args.referenceBalanceIn | 32 bytes (X₀ - initial virtual input reserve)
    /// @param args.referenceBalanceOut | 32 bytes (Y₀ - initial virtual output reserve)
    function _depletionFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 minFeeBps, uint256 maxFeeBps, uint256 refBalanceIn, uint256 refBalanceOut) = FeeArgsBuilder.parseDepletionFee(args);

        if (ctx.query.isExactIn) {
            ctx.runLoop();
            uint256 feeAmount = _computeImbalanceFee(
                ctx.swap.amountOut,
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                refBalanceIn,
                refBalanceOut,
                minFeeBps,
                maxFeeBps
            );
            ctx.swap.amountOut -= feeAmount;
        } else {
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            ctx.swap.amountOut = _solveGrossForImbalanceFee(
                takerDefinedAmountOut,
                ctx.swap.balanceIn,
                ctx.swap.balanceOut,
                refBalanceIn,
                refBalanceOut,
                minFeeBps,
                maxFeeBps
            );
            ctx.runLoop();
            ctx.swap.amountOut = takerDefinedAmountOut;
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

    /// @dev Compute imbalance-based fee clamped to [minFeeBps, maxFeeBps]
    function _computeImbalanceFee(
        uint256 amount,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 refBalanceIn,
        uint256 refBalanceOut,
        uint256 minFeeBps,
        uint256 maxFeeBps
    ) internal pure returns (uint256 fee) {
        if (refBalanceIn == 0 || refBalanceOut == 0 || amount == 0) return 0;

        uint256 effectiveFeeBps = _computeEffectiveFeeBps(
            balanceIn, balanceOut, refBalanceIn, refBalanceOut, minFeeBps, maxFeeBps
        );

        fee = effectiveFeeBps * amount / BPS;
        if (fee > amount) fee = amount;
    }

    /// @dev Solve for grossOut given netOut: grossOut = netOut × BPS / (BPS - effectiveFeeBps)
    function _solveGrossForImbalanceFee(
        uint256 netOut,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 refBalanceIn,
        uint256 refBalanceOut,
        uint256 minFeeBps,
        uint256 maxFeeBps
    ) internal pure returns (uint256 grossOut) {
        if (refBalanceIn == 0 || refBalanceOut == 0 || netOut == 0) return netOut;

        uint256 effectiveFeeBps = _computeEffectiveFeeBps(
            balanceIn, balanceOut, refBalanceIn, refBalanceOut, minFeeBps, maxFeeBps
        );

        uint256 denominator = BPS - effectiveFeeBps;
        if (denominator == 0) return balanceOut;

        grossOut = netOut * BPS / denominator;
        if (grossOut > balanceOut) grossOut = balanceOut;
    }

    /// @dev Solve for grossIn given netIn: grossIn = netIn × BPS / (BPS - effectiveFeeBps)
    function _solveGrossForImbalanceFeeIn(
        uint256 netIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 refBalanceIn,
        uint256 refBalanceOut,
        uint256 minFeeBps,
        uint256 maxFeeBps
    ) internal pure returns (uint256 grossIn) {
        if (refBalanceIn == 0 || refBalanceOut == 0 || netIn == 0) return netIn;

        uint256 effectiveFeeBps = _computeEffectiveFeeBps(
            balanceIn, balanceOut, refBalanceIn, refBalanceOut, minFeeBps, maxFeeBps
        );

        uint256 denominator = BPS - effectiveFeeBps;
        if (denominator == 0) return type(uint256).max;

        grossIn = netIn * BPS / denominator;
    }

    /// @dev Compute effective fee rate based on current imbalance
    function _computeEffectiveFeeBps(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 refBalanceIn,
        uint256 refBalanceOut,
        uint256 minFeeBps,
        uint256 maxFeeBps
    ) internal pure returns (uint256 effectiveFeeBps) {
        uint256 midFeeBps = (minFeeBps + maxFeeBps) / 2;

        uint256 currentCross = balanceIn * refBalanceOut;
        uint256 refCross = refBalanceIn * balanceOut;

        if (currentCross > refCross) {
            // Depleting: higher fee up to maxFeeBps
            uint256 imbalance = (currentCross - refCross) * BPS / refCross;
            uint256 rawFeeBps = midFeeBps + midFeeBps * imbalance / BPS;
            effectiveFeeBps = rawFeeBps > maxFeeBps ? maxFeeBps : rawFeeBps;
        } else if (currentCross < refCross) {
            // Restoring: lower fee down to minFeeBps
            uint256 imbalance = (refCross - currentCross) * BPS / refCross;
            uint256 reduction = midFeeBps * imbalance / BPS;
            uint256 rawFeeBps = midFeeBps > reduction ? midFeeBps - reduction : 0;
            effectiveFeeBps = rawFeeBps < minFeeBps ? minFeeBps : rawFeeBps;
        } else {
            effectiveFeeBps = midFeeBps;
        }
    }
}
