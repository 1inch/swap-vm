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

    struct LimitOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
    }

    struct XYCConcentrateOrder {
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint24 feeBps;
    }

    struct ProtocolFlatFee {
        FeeProtocol.ReceiverConfig[] receivers;
        FeeProtocol.ProviderConfig[] providers;
    }

    struct ProtocolFee {
        FeeProtocol.ReceiverConfig[] receivers;
        FeeProtocol.ProviderConfig[] providers;
        uint216 surplusEstimate;
    }

    struct LinearScale {
        uint40 timestamp;
        uint16[] durations;
        uint24[] scales;
    }

    struct BaseFeeAdjustment {
        uint64 baseGasPrice;
        uint96 ethPrice;
        uint24 gasAmount;
        uint24 capBps;
    }

    struct RateCut {
        uint64 rateA;
        uint64 rateB;
    }

    struct LimitOrderFullAmountFeeIn {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        uint32 bitIndex;
        ProtocolFlatFee fee;
    }

    struct LimitOrderFeeIn {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ProtocolFlatFee fee;
    }

    struct ScaledLimitOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ProtocolFee fee;
        LinearScale scale;
    }

    struct AdjustedLimitOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        ProtocolFee fee;
        LinearScale scale;
        BaseFeeAdjustment gasAdjustment;
        uint24 fulfillBonusBps;
        RateCut rateCut;
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

    function buildLimitOrder(
        bytes[] calldata prefix,
        LimitOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = LimitSwap.build(ptr, args.direction);

        return ptr.resolve();
    }

    function buildXYCConcentrateOrder(
        bytes[] calldata prefix,
        XYCConcentrateOrder calldata args
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

    /// @notice StaticBalances - FeeProtocol (in, flat only) - InvalidateBit - LimitSwapFullAmount
    function buildLimitOrderFullAmountFeeIn(
        bytes[] calldata prefix,
        LimitOrderFullAmountFeeIn calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, 0) +
            InvalidateBit.sizeOf(args.bitIndex) +
            LimitSwapFullAmount.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, 0);
        ptr = InvalidateBit.build(ptr, args.bitIndex);
        ptr = LimitSwapFullAmount.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }

    /// @notice StaticBalances - FeeProtocol (in, flat only) - InvalidateTokenOut - LimitSwap
    function buildLimitOrderFeeIn(
        bytes[] calldata prefix,
        LimitOrderFeeIn calldata args
    ) internal pure returns (bytes memory slice) {
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

    /// @notice StaticBalances - FeeProtocol (in) - PiecewiseLinearScaleBalanceIn - InvalidateTokenOut - LimitSwap
    function buildScaledLimitOrderFeeIn(
        bytes[] calldata prefix,
        ScaledLimitOrder calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate) +
            PiecewiseLinearScaleBalanceIn.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
            InvalidateTokenOut.sizeOf() +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate);
        ptr = PiecewiseLinearScaleBalanceIn.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
        ptr = InvalidateTokenOut.build(ptr);
        ptr = LimitSwap.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }

    /// @notice StaticBalances - FeeProtocol (out) - PiecewiseLinearScaleBalanceOut - InvalidateTokenIn - LimitSwap
    function buildScaledLimitOrderFeeOut(
        bytes[] calldata prefix,
        ScaledLimitOrder calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(false, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate) +
            PiecewiseLinearScaleBalanceOut.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
            InvalidateTokenIn.sizeOf() +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, false, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate);
        ptr = PiecewiseLinearScaleBalanceOut.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
        ptr = InvalidateTokenIn.build(ptr);
        ptr = LimitSwap.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }

    /// @notice StaticBalances - FeeProtocol (in) - PiecewiseLinearScaleBalanceIn - BaseFeeAdjusterBalanceIn
    ///   - FulfillBonusBalanceIn - BalanceScaleCutIn - InvalidateTokenOut - LimitSwap
    function buildAdjustedLimitOrderFeeIn(
        bytes[] calldata prefix,
        AdjustedLimitOrder calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(true, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate) +
            PiecewiseLinearScaleBalanceIn.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
            BaseFeeAdjusterBalanceIn.sizeOf(args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps) +
            FulfillBonusBalanceIn.sizeOf(args.fulfillBonusBps) +
            BalanceScaleCutIn.sizeOf(args.rateCut.rateA, args.rateCut.rateB) +
            InvalidateTokenOut.sizeOf() +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, true, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate);
        ptr = PiecewiseLinearScaleBalanceIn.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
        ptr = BaseFeeAdjusterBalanceIn.build(ptr, args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps);
        ptr = FulfillBonusBalanceIn.build(ptr, args.fulfillBonusBps);
        ptr = BalanceScaleCutIn.build(ptr, args.rateCut.rateA, args.rateCut.rateB);
        ptr = InvalidateTokenOut.build(ptr);
        ptr = LimitSwap.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }

    /// @notice StaticBalances - FeeProtocol (out) - PiecewiseLinearScaleBalanceOut - BaseFeeAdjusterBalanceOut
    ///   - FulfillBonusBalanceOut - BalanceScaleCutOut - InvalidateTokenIn - LimitSwap
    function buildAdjustedLimitOrderFeeOut(
        bytes[] calldata prefix,
        AdjustedLimitOrder calldata args
    ) internal pure returns (bytes memory slice) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            FeeProtocol.sizeOf(false, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate) +
            PiecewiseLinearScaleBalanceOut.sizeOf(args.scale.timestamp, args.scale.durations, args.scale.scales) +
            BaseFeeAdjusterBalanceOut.sizeOf(args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps) +
            FulfillBonusBalanceOut.sizeOf(args.fulfillBonusBps) +
            BalanceScaleCutOut.sizeOf(args.rateCut.rateA, args.rateCut.rateB) +
            InvalidateTokenIn.sizeOf() +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = FeeProtocol.build(ptr, false, args.fee.receivers, args.fee.providers, args.fee.surplusEstimate);
        ptr = PiecewiseLinearScaleBalanceOut.build(ptr, args.scale.timestamp, args.scale.durations, args.scale.scales);
        ptr = BaseFeeAdjusterBalanceOut.build(ptr, args.gasAdjustment.baseGasPrice, args.gasAdjustment.ethPrice, args.gasAdjustment.gasAmount, args.gasAdjustment.capBps);
        ptr = FulfillBonusBalanceOut.build(ptr, args.fulfillBonusBps);
        ptr = BalanceScaleCutOut.build(ptr, args.rateCut.rateA, args.rateCut.rateB);
        ptr = InvalidateTokenIn.build(ptr);
        ptr = LimitSwap.build(ptr, args.direction);

        (slice, ) = ptr.resolveShrink();
    }
}
