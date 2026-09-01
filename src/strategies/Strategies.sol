// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { StaticBalances } from "../instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../instructions/LimitSwap.sol";
import { XYCConcentrateSwap } from "../instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../instructions/FeeFlat.sol";
import { FeeProtocol } from "../instructions/FeeProtocol.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut } from "../instructions/Invalidators.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut } from "../instructions/PiecewiseLinearScale.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../instructions/BaseFeeAdjuster.sol";
import { FulfillBonusBalanceIn, FulfillBonusBalanceOut } from "../instructions/FulfillBonus.sol";
import { BalanceScaleCutIn, BalanceScaleCutOut } from "../instructions/BalanceScaleCut.sol";
import {
    OnlyTakerTokenBalanceNonZero,
    OnlyTakerTokenBalanceGte,
    OnlyTakerTokenSupplyShareGte,
    OnlyTxOriginTokenBalanceNonZero
} from "../instructions/TokenValidators.sol";
import { Deadline, Salt } from "../instructions/Controls.sol";
import { ValidateSeriesEpoch } from "../instructions/SeriesEpochManager.sol";

/// @notice Library for on-chain orders validation
///   Prefixes does not impact amounts calculation, so arbitrary allowed
///   Proposed strategies holds some invariants such as maker min/max swap rate
library Strategies {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;

    error PrefixInvalidLength(uint256 length, uint256 expected);
    error PrefixUnregistered(uint8 opcode);

    struct ConfProtocolFee {
        FeeProtocol.ReceiverConfig[] receivers;
        FeeProtocol.ProviderConfig[] providers;
    }

    struct ConfPiecewiseLinearScale {
        uint40 timestamp;
        uint16[] durations;
        uint24[] scales;
    }

    struct ConfBaseFeeAdjustment {
        uint64 baseGasPrice;
        uint96 ethPrice;
        uint24 gasAmount;
        uint24 capBps;
    }

    struct ConfRateCut {
        uint64 rateA;
        uint64 rateB;
    }

    struct IsazOrder {
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint24 feeBps;
    }

    struct WunjuOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        uint32 bitIndex;
        ConfProtocolFee fee;
    }

    struct UruzOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ConfProtocolFee fee;
    }

    struct ThurisazOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ConfProtocolFee fee;
        uint216 surplusEstimate;
        ConfPiecewiseLinearScale scale;
    }

    struct FusionOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ConfProtocolFee fee;
        uint216 surplusEstimate;
        ConfPiecewiseLinearScale scale;
        ConfBaseFeeAdjustment gasAdjustment;
        uint24 fulfillBonusBps;
        ConfRateCut rateCut;
    }

    uint256 private constant _prefixBitmap =
        (1 << uint256(OnlyTakerTokenBalanceNonZero.opcode)) |
        (1 << uint256(OnlyTakerTokenBalanceGte.opcode)) |
        (1 << uint256(OnlyTakerTokenSupplyShareGte.opcode)) |
        (1 << uint256(OnlyTxOriginTokenBalanceNonZero.opcode)) |
        (1 << uint256(Deadline.opcode)) |
        (1 << uint256(Salt.opcode)) |
        (1 << uint256(ValidateSeriesEpoch.opcode));

    /// @notice Prefixes are validation-only opcodes which do not change registers
    ///   Wrongly built prefix instructions do not affect strategy calculations,
    ///   so checking only opcode is in prefix bitmap and length consistency is enough
    function _checkPrefix(bytes[] calldata instructions) private pure returns (uint256 prefixSize) {
        for (uint256 i; i < instructions.length; i++) {
            bytes calldata instruction = instructions[i];
            uint8 opcode = instruction.at(0).asU8();
            uint256 length = 2 + instruction.at(1).asU8();

            require(instruction.length == length, PrefixInvalidLength(instruction.length, length));
            require(_prefixBitmap & (1 << opcode) != 0, PrefixUnregistered(opcode));

            prefixSize += instruction.length;
        }
    }

    /// @notice FeeFlatIn - XYCConcentrateSwap
    /// @notice Aqua only
    /// @dev Concentrated-liquidity AMM position quoting inside the [sqrtPriceMin, sqrtPriceMax] price range
    ///   No balances opcode included: reserves are shipped to Aqua and re-read on every fill,
    ///   so the position is refillable in both directions and accumulates the flat token-in fee
    function buildIsazOrder(
        bytes[] calldata prefix,
        IsazOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            FeeFlatIn.sizeOf(args.feeBps) +
            XYCConcentrateSwap.sizeOf(args.sqrtPriceMin, args.sqrtPriceMax)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = FeeFlatIn.build(ptr, args.feeBps);
        ptr = XYCConcentrateSwap.build(ptr, args.sqrtPriceMin, args.sqrtPriceMax);

        return ptr.resolve();
    }

    /// @notice StaticBalances - FeeProtocol - InvalidateBit - LimitSwapFullAmount
    /// @dev All-or-nothing limit order executable at most once: the taker amount must cover the full balance,
    ///   both legs settle exactly at balanceA / balanceB and InvalidateBit burns a maker-scoped nonce
    ///   The flat protocol fee is charged in the token opposite to the maker's exact axis keeping that leg exact,
    ///   the surplus estimate is not encoded, so receivers and providers must not take surplus fees
    function buildWunjuOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        WunjuOrder calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(!makerExactIn, args.fee.receivers, args.fee.providers, 0) +
            InvalidateBit.sizeOf(args.bitIndex) +
            LimitSwapFullAmount.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, !makerExactIn, args.fee.receivers, args.fee.providers, 0);
        ptr = InvalidateBit.build(ptr, args.bitIndex);
        ptr = LimitSwapFullAmount.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }

    /// @notice StaticBalances - FeeProtocol - InvalidateToken - LimitSwap
    /// @dev Partially fillable limit order at the fixed balanceA / balanceB rate: the invalidator caps
    ///   cumulative fills over the maker's exact axis by the corresponding balance, every fill shrinking
    ///   the remaining balances pro-rata, while the flat protocol fee is taken in the opposite (floating)
    ///   axis token on top of the tracked amounts
    ///   The surplus estimate is not encoded, so receivers and providers must not take surplus fees
    function buildUruzOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        UruzOrder calldata args
    ) internal pure returns (bytes memory slice) {
        if (makerExactIn) {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(false, args.fee.receivers, args.fee.providers, 0) +
                InvalidateTokenIn.sizeOf() +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, false, args.fee.receivers, args.fee.providers, 0);
            ptr = InvalidateTokenIn.build(ptr);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        } else {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, 0) +
                InvalidateTokenOut.sizeOf() +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, 0);
            ptr = InvalidateTokenOut.build(ptr);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        }
    }

    /// @notice StaticBalances - FeeProtocol+Surplus - PLS - InvalidateToken - LimitSwap
    /// @dev Dutch-auction limit order: fills are tracked over the maker's exact axis as in Uruz while
    ///   the floating axis balance follows the piecewise-linear time schedule — maker exact in schedules
    ///   the balance out (maker pays at max the 1.0-scale balance out), maker exact out schedules the
    ///   balance in (maker receives at least the lowest-scale balance in)
    ///   Beyond flat fees the receivers may take a surplus cut of the execution better than surplusEstimate,
    ///   the estimate being pro-rated by the invalidator to the filled portion of the order
    /// @dev Invariant: every fill settles at the scheduled rate or better for the maker —
    ///   maker exact in pays at most `amountIn * scaleValue(balanceOut, biggestScale) / balanceIn` in token out,
    ///   maker exact out receives at least `amountOut * scaleValue(balanceIn, lowestScale) / balanceOut` in token in
    ///   Surplus fee respects the invariant only for surplusEstimate within the scheduled bound:
    ///   at least the lowest-scale receipt or at most the biggest-scale payment respectively
    function buildThurisazOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        ThurisazOrder calldata args
    ) internal pure returns (bytes memory slice) {
        if (makerExactIn) {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(false, args.fee.receivers, args.fee.providers, args.surplusEstimate) +
                PiecewiseLinearScaleBalanceOut.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
                InvalidateTokenIn.sizeOf() +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, false, args.fee.receivers, args.fee.providers, args.surplusEstimate);
            ptr = PiecewiseLinearScaleBalanceOut.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
            ptr = InvalidateTokenIn.build(ptr);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        } else {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, args.surplusEstimate) +
                PiecewiseLinearScaleBalanceIn.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
                InvalidateTokenOut.sizeOf() +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, args.surplusEstimate);
            ptr = PiecewiseLinearScaleBalanceIn.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
            ptr = InvalidateTokenOut.build(ptr);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        }
    }

    /// @notice StaticBalances - FeeProtocol+Surplus - PLS - BaseFeeAdjuster - InvalidateToken - FulfillBonus - BalanceScaleCut - LimitSwap
    /// @dev Thurisaz auction extended with taker execution incentives and a maker rate guard, all adjusting
    ///   the floating axis balance: BaseFeeAdjuster improves the taker rate to compensate the fill gas above
    ///   baseGasPrice (capped by capBps of the scheduled whole-order balance), FulfillBonus improves the taker rate by
    ///   fulfillBonusBps for the fill closing the whole remaining amount, and BalanceScaleCut bounds the final
    ///   balances by the rateA / rateB rate protecting the maker from the adjustments stacking beyond it
    /// @dev Invariant: whatever the schedule, gas adjustment and bonus stack to, every fill settles at the
    ///   BalanceScaleCut rate or better for the maker — maker exact in pays at most `amountIn * rateOut / rateIn`
    ///   in token out, maker exact out receives at least `amountOut * rateIn / rateOut` in token in
    ///   Surplus fee respects the invariant only for surplusEstimate within the guarded bound:
    ///   at least the cut-floor receipt or at most the cut-cap payment respectively
    function buildFusionOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        FusionOrder calldata args
    ) internal pure returns (bytes memory slice) {
        if (makerExactIn) {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(false, args.fee.receivers, args.fee.providers, args.surplusEstimate) +
                PiecewiseLinearScaleBalanceOut.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
                BaseFeeAdjusterBalanceOut.sizeOf(args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps) +
                InvalidateTokenIn.sizeOf() +
                FulfillBonusBalanceOut.sizeOf(args.fulfillBonusBps) +
                BalanceScaleCutOut.sizeOf(args.rateCut.rateA, args.rateCut.rateB) +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, false, args.fee.receivers, args.fee.providers, args.surplusEstimate);
            ptr = PiecewiseLinearScaleBalanceOut.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
            ptr = BaseFeeAdjusterBalanceOut.build(ptr, args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps);
            ptr = InvalidateTokenIn.build(ptr);
            ptr = FulfillBonusBalanceOut.build(ptr, args.fulfillBonusBps);
            ptr = BalanceScaleCutOut.build(ptr, args.rateCut.rateA, args.rateCut.rateB);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        } else {
            MemoryPtr ptr = MemoryPtrLib.alloc(
                _checkPrefix(prefix) +
                StaticBalances.sizeOf(args.balanceA, args.balanceB) +
                FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, args.surplusEstimate) +
                PiecewiseLinearScaleBalanceIn.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
                BaseFeeAdjusterBalanceIn.sizeOf(args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps) +
                InvalidateTokenOut.sizeOf() +
                FulfillBonusBalanceIn.sizeOf(args.fulfillBonusBps) +
                BalanceScaleCutIn.sizeOf(args.rateCut.rateA, args.rateCut.rateB) +
                LimitSwap.sizeOf(args.direction)
            );

            for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
            ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
            ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, args.surplusEstimate);
            ptr = PiecewiseLinearScaleBalanceIn.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
            ptr = BaseFeeAdjusterBalanceIn.build(ptr, args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps);
            ptr = InvalidateTokenOut.build(ptr);
            ptr = FulfillBonusBalanceIn.build(ptr, args.fulfillBonusBps);
            ptr = BalanceScaleCutIn.build(ptr, args.rateCut.rateA, args.rateCut.rateB);
            ptr = LimitSwap.build(ptr, args.direction);

            (slice, ) = ptr.resolveShrink();
        }
    }
}
