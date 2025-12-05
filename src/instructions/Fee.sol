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

    error DepletionFeeMissingFeeBPS();
    error DepletionFeeMissingReferenceBalance();

    /// @notice Build args for depletion-based fee (enforces additivity for concentrated liquidity)
    /// @param feeBps Base fee rate for small swaps (1e9 = 100%)
    /// @param referenceBalance Initial output reserve (Y₀) - typically virtual balance after concentration
    /// @dev The fee increases as pool gets depleted, penalizing split swaps
    function buildDepletionFee(uint32 feeBps, uint256 referenceBalance) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps, referenceBalance);
    }

    function parseDepletionFee(bytes calldata args) internal pure returns (uint32 feeBps, uint256 referenceBalance) {
        feeBps = uint32(bytes4(args.slice(0, 4, DepletionFeeMissingFeeBPS.selector)));
        referenceBalance = uint256(bytes32(args.slice(4, 36, DepletionFeeMissingReferenceBalance.selector)));
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

    /// @notice Depletion fee on input - overcharges splits to compensate for AMM advantage
    /// @dev fee = baseFee × amountIn × (1 + penalty × startingDepletion)
    /// @dev where startingDepletion = (refBalance - currentBalanceOut) / refBalance
    /// @dev
    /// @dev ADDITIVITY MECHANISM:
    /// @dev   Same as output version but fee is charged on input side.
    /// @dev   Tracks OUTPUT depletion since that drives AMM state changes.
    /// @dev
    /// @param args.feeBps | 4 bytes (base fee rate in bps, 1e9 = 100%)
    /// @param args.referenceBalance | 32 bytes (Y₀ - initial virtual output reserve)
    function _depletionFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, uint256 refBalance) = FeeArgsBuilder.parseDepletionFee(args);

        if (ctx.query.isExactIn) {
            // Fee charged on input, reduce what goes to AMM
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            uint256 currentBalance = ctx.swap.balanceOut; // Track OUTPUT depletion
            uint256 feeAmount = _computeSuperlinearFee(ctx.swap.amountIn, currentBalance, refBalance, feeBps);
            ctx.swap.amountIn -= feeAmount;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();
            // AMM computed net input needed, add fee to get gross input
            uint256 currentBalance = ctx.swap.balanceOut; // Pre-swap output balance
            ctx.swap.amountIn = _solveGrossForSuperlinearFeeIn(ctx.swap.amountIn, currentBalance, refBalance, feeBps);
        }
    }

    /// @notice Depletion fee on output - overcharges splits to compensate for AMM advantage
    /// @dev fee = baseFee × amountOut × (1 + penalty × startingDepletion)
    /// @dev where startingDepletion = (refBalance - currentBalance) / refBalance
    /// @dev
    /// @dev ADDITIVITY MECHANISM:
    /// @dev   Single swap starts from depletion=0, so penalty=0.
    /// @dev   Split swaps: first gets no penalty, second starts from non-zero depletion.
    /// @dev   The amplified penalty overcharges splits to offset the AMM's state-dependent advantage.
    /// @dev
    /// @dev   For concentrated liquidity: penalty is amplified by refBalance/currentBalance ratio
    /// @dev   to handle the high virtual reserves from concentration.
    /// @dev
    /// @param args.feeBps | 4 bytes (base fee rate in bps, 1e9 = 100%)
    /// @param args.referenceBalance | 32 bytes (Y₀ - initial virtual output reserve)
    function _depletionFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, uint256 refBalance) = FeeArgsBuilder.parseDepletionFee(args);

        if (ctx.query.isExactIn) {
            ctx.runLoop();

            uint256 currentBalance = ctx.swap.balanceOut;
            uint256 feeAmount = _computeSuperlinearFee(ctx.swap.amountOut, currentBalance, refBalance, feeBps);
            ctx.swap.amountOut -= feeAmount;
        } else {
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            uint256 currentBalance = ctx.swap.balanceOut;
            ctx.swap.amountOut = _solveGrossForSuperlinearFee(takerDefinedAmountOut, currentBalance, refBalance, feeBps);
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

    /// @dev Compute superlinear fee with strong depletion penalty
    /// @dev fee = baseFee × amountOut × (1 + penaltyRate × startingDepletion) / BPS
    /// @dev where startingDepletion = (refBalance - currentBalance) / refBalance
    /// @dev
    /// @dev KEY INSIGHT:
    /// @dev   Single swap starts from depletion=0, so penalty=0.
    /// @dev   Second split swap starts from depletion=out₁/ref, gets penalized.
    /// @dev   Penalty must be large enough to offset AMM's split advantage.
    /// @dev   For concentrated liquidity: penaltyRate ≈ refBalance / amountTypical
    function _computeSuperlinearFee(
        uint256 amountOut,
        uint256 currentBalance,
        uint256 refBalance,
        uint256 feeBps
    ) internal pure returns (uint256 fee) {
        if (refBalance == 0 || amountOut == 0) return 0;

        // Starting depletion = how much was consumed BEFORE this swap, scaled by BPS
        uint256 startDepletion = currentBalance >= refBalance
            ? 0
            : (refBalance - currentBalance) * BPS / refBalance;

        // Strong penalty: penaltyRate scales with refBalance to handle concentration
        // penalty = 1 + startDepletion (at depletion=100%, fee doubles)
        // But we need MUCH stronger for concentrated liquidity where swaps are small vs refBalance
        // Use: penalty = 1 + startDepletion × refBalance / currentBalance (amplified)
        uint256 penaltyMultiplier;
        if (currentBalance > 0 && startDepletion > 0) {
            // Amplify penalty by concentration ratio
            uint256 amplifiedDepletion = startDepletion * refBalance / currentBalance;
            if (amplifiedDepletion > BPS) amplifiedDepletion = BPS; // Cap at 100%
            penaltyMultiplier = BPS + amplifiedDepletion;
        } else {
            penaltyMultiplier = BPS;
        }

        // fee = feeBps × amountOut × penaltyMultiplier / BPS²
        fee = feeBps * amountOut * penaltyMultiplier / (BPS * BPS);
    }

    /// @dev Solve for grossOut given netOut using binary search
    function _solveGrossForSuperlinearFee(
        uint256 netOut,
        uint256 currentBalance,
        uint256 refBalance,
        uint256 feeBps
    ) internal pure returns (uint256 grossOut) {
        // Binary search bounds
        uint256 lo = netOut;

        // Upper bound estimate (with max penalty of 3x)
        uint256 hi = feeBps < BPS / 3
            ? Math.ceilDiv(netOut * BPS, BPS - 3 * feeBps)
            : netOut * 2;
        if (hi > currentBalance) hi = currentBalance;

        // Binary search
        for (uint256 i = 0; i < 60; i++) {
            grossOut = (lo + hi) / 2;
            if (lo >= hi) break;

            uint256 feeForGross = _computeSuperlinearFee(grossOut, currentBalance, refBalance, feeBps);
            uint256 netForGross = grossOut > feeForGross ? grossOut - feeForGross : 0;

            if (netForGross == netOut) {
                break;
            } else if (netForGross < netOut) {
                lo = grossOut + 1;
            } else {
                hi = grossOut;
            }
        }
    }

    /// @dev Solve for grossIn given netIn (what AMM needs) using binary search
    /// @dev For input fees: grossIn - fee(grossIn) = netIn
    function _solveGrossForSuperlinearFeeIn(
        uint256 netIn,
        uint256 currentBalance,
        uint256 refBalance,
        uint256 feeBps
    ) internal pure returns (uint256 grossIn) {
        // Binary search bounds
        uint256 lo = netIn;

        // Upper bound estimate (with max penalty of 3x)
        uint256 hi = feeBps < BPS / 3
            ? Math.ceilDiv(netIn * BPS, BPS - 3 * feeBps)
            : netIn * 2;

        // Binary search
        for (uint256 i = 0; i < 60; i++) {
            grossIn = (lo + hi + 1) / 2; // Round up for ceiling behavior
            if (lo >= hi) break;

            uint256 feeForGross = _computeSuperlinearFee(grossIn, currentBalance, refBalance, feeBps);
            uint256 netForGross = grossIn > feeForGross ? grossIn - feeForGross : 0;

            if (netForGross == netIn) {
                break;
            } else if (netForGross < netIn) {
                lo = grossIn;
            } else {
                hi = grossIn - 1;
            }
        }
    }
}
