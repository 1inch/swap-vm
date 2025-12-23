// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "./Calldata.sol";
import { CalldataPtr, CalldataPtrLib } from "./CalldataPtr.sol";
import { ITakerCallbacks } from "../interfaces/ITakerCallbacks.sol";

type TakerTraits is uint256;

library TakerTraitsLib {
    using SafeCast for uint256;
    using Calldata for bytes;
    using CalldataPtrLib for CalldataPtr;
    using TakerTraitsLib for TakerTraits;

    error TakerTraitsMissingTraits();
    error TakerTraitsMissingHookData();
    error TakerTraitsMissingHookTarget();
    error TakerTraitsMissingHasPreTransferInFlag();
    error TakerTraitsMissingHasPreTransferOutFlag();
    error TakerTraitsThresholdLengthInvalid(bytes threshold);
    error TakerTraitsNonExactThresholdAmountIn(uint256 amountIn, uint256 amountThreshold);
    error TakerTraitsNonExactThresholdAmountOut(uint256 amountOut, uint256 amountThreshold);
    error TakerTraitsInsufficientMinOutputAmount(uint256 amountOut, uint256 amountOutMin);
    error TakerTraitsAmountOutMustBeGreaterThanZero(uint256 amountOut);
    error TakerTraitsExceedingMaxInputAmount(uint256 amountIn, uint256 amountInMax);
    error TakerTraitsTakerAmountInMismatch(uint256 takerAmount, uint256 computedAmount);
    error TakerTraitsTakerAmountOutMismatch(uint256 takerAmount, uint256 computedAmount);
    error TakerTraitsDeadlineExpired();

    struct Args {
        address taker;
        bool isExactIn;
        bool shouldUnwrapWeth;
        bool isStrictThresholdAmount;
        bool isFirstTransferFromTaker;
        bool useTransferFromAndAquaPush;
        bytes threshold;
        address to;
        uint40 deadline;

        bool hasPreTransferInCallback;
        bool hasPreTransferOutCallback;
        bytes preTransferInHookData;
        bytes postTransferInHookData;
        bytes preTransferOutHookData;
        bytes postTransferOutHookData;
        bytes preTransferInCallbackData;
        bytes preTransferOutCallbackData;
        bytes instructionsArgs;
        bytes signature;
    }

    enum TakerDataSlices {
        Threshold,
        To,
        Deadline,
        PreTransferInHook,
        PostTransferInHook,
        PreTransferOutHook,
        PostTransferOutHook,
        PreTransferInCallback,
        PreTransferOutCallback,
        InstructionsArgs,
        Signature
    }

    uint256 constant internal TAKER_DATA_SLICES_INDEXES_BIT_OFFSET = 16;
    uint256 constant internal TAKER_DATA_SLICES_INDEX_BIT_MAP = type(uint16).max;
    uint256 constant internal TAKER_DATA_SLICES_INDEX_BIT_SIZE_SHL = 4;

    uint16 constant internal IS_EXACT_IN_BIT_FLAG = 0x0001;
    uint16 constant internal SHOULD_UNWRAP_BIT_FLAG = 0x0002;
    uint16 constant internal HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG = 0x0004;
    uint16 constant internal HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG = 0x0008;
    uint16 constant internal IS_STRICT_THRESHOLD_BIT_FLAG = 0x0010;
    uint16 constant internal IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG = 0x0020;
    uint16 constant internal USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG = 0x0040;

    function build(Args memory args) internal pure returns (bytes memory packed) {
        require(args.threshold.length == 32 || args.threshold.length == 0, TakerTraitsThresholdLengthInvalid(args.threshold));

        if (args.preTransferInCallbackData.length > 0) {
            require(args.hasPreTransferInCallback, TakerTraitsMissingHasPreTransferInFlag());
        }
        if (args.preTransferOutCallbackData.length > 0) {
            require(args.hasPreTransferOutCallback, TakerTraitsMissingHasPreTransferOutFlag());
        }

        uint256 index0 = args.threshold.length;
        uint256 index1 = (index0 + (args.to != address(0) && args.to != args.taker ? 20 : 0));
        uint256 index2 = (index1 + (args.deadline != 0 ? 5 : 0));
        uint256 index3 = (index2 + args.preTransferInHookData.length.toUint16());
        uint256 index4 = (index3 + args.postTransferInHookData.length).toUint16();
        uint256 index5 = (index4 + args.preTransferOutHookData.length).toUint16();
        uint256 index6 = (index5 + args.postTransferOutHookData.length).toUint16();
        uint256 index7 = (index6 + args.preTransferInCallbackData.length).toUint16();
        uint256 index8 = (index7 + args.preTransferOutCallbackData.length).toUint16();
        uint256 index9 = (index8 + args.instructionsArgs.length).toUint16();

        uint160 slicesIndexes = uint160(
            (uint160(index0) << 0) |
            (uint160(index1) << 16) |
            (uint160(index2) << 32) |
            (uint160(index3) << 48) |
            (uint160(index4) << 64) |
            (uint160(index5) << 80) |
            (uint160(index6) << 96) |
            (uint160(index7) << 112) |
            (uint160(index8) << 128) |
            (uint160(index9) << 144)
        );

        packed = abi.encodePacked(
            slicesIndexes,
            (args.isExactIn ? IS_EXACT_IN_BIT_FLAG : 0) |
            (args.shouldUnwrapWeth ? SHOULD_UNWRAP_BIT_FLAG : 0) |
            (args.isStrictThresholdAmount ? IS_STRICT_THRESHOLD_BIT_FLAG : 0) |
            (args.isFirstTransferFromTaker ? IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG : 0) |
            (args.useTransferFromAndAquaPush ? USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG : 0) |
            (args.hasPreTransferInCallback ? HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG : 0) |
            (args.hasPreTransferOutCallback ? HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG : 0),
            args.threshold,
            (args.to != address(0) && args.to != args.taker ? abi.encodePacked(args.to) : bytes("")),
            (args.deadline != 0 ? abi.encodePacked(args.deadline) : bytes("")),
            args.preTransferInHookData,
            args.postTransferInHookData,
            args.preTransferOutHookData,
            args.postTransferOutHookData,
            args.preTransferInCallbackData,
            args.preTransferOutCallbackData,
            args.instructionsArgs,
            args.signature
        );
    }

    function parse(bytes calldata data) internal pure returns (TakerTraits traits, bytes calldata tail) {
        traits = TakerTraits.wrap(uint176(bytes22(data.slice(0, 22, TakerTraitsMissingTraits.selector))));
        tail = data.slice(22);
    }

    function validate(TakerTraits traits, bytes calldata takerData, uint256 takerAmount, uint256 amountIn, uint256 amountOut) internal view {
        require(amountOut > 0, TakerTraitsAmountOutMustBeGreaterThanZero(amountOut));

        uint40 takerDeadline = traits.deadline(takerData);
        require(takerDeadline == 0 || block.timestamp <= takerDeadline, TakerTraitsDeadlineExpired());

        if (traits.isExactIn()) {
            require(takerAmount == amountIn, TakerTraitsTakerAmountInMismatch(takerAmount, amountIn));
            (bool hasThreshold, uint256 thresholdAmount) = traits.threshold(takerData);
            if (hasThreshold) {
                if (traits.isStrictThresholdAmount()) {
                    require(amountOut == thresholdAmount, TakerTraitsNonExactThresholdAmountOut(amountOut, thresholdAmount));
                } else {
                    require(amountOut >= thresholdAmount, TakerTraitsInsufficientMinOutputAmount(amountOut, thresholdAmount));
                }
            }
        } else {
            require(takerAmount == amountOut, TakerTraitsTakerAmountOutMismatch(takerAmount, amountOut));
            (bool hasThreshold, uint256 thresholdAmount) = traits.threshold(takerData);
            if (hasThreshold) {
                if (traits.isStrictThresholdAmount()) {
                    require(amountIn == thresholdAmount, TakerTraitsNonExactThresholdAmountIn(amountIn, thresholdAmount));
                } else {
                    require(amountIn <= thresholdAmount, TakerTraitsExceedingMaxInputAmount(amountIn, thresholdAmount));
                }
            }
        }
    }

    function isExactIn(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & IS_EXACT_IN_BIT_FLAG) != 0;
    }

    function shouldUnwrapWeth(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & SHOULD_UNWRAP_BIT_FLAG) != 0;
    }

    function hasPreTransferInCallback(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG) != 0;
    }

    function hasPreTransferOutCallback(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG) != 0;
    }

    function isStrictThresholdAmount(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & IS_STRICT_THRESHOLD_BIT_FLAG) != 0;
    }

    function useTransferFromAndAquaPush(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG) != 0;
    }

    function isFirstTransferFromTaker(TakerTraits traits) internal pure returns (bool) {
        return (TakerTraits.unwrap(traits) & IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG) != 0;
    }

    function threshold(TakerTraits traits, bytes calldata data) internal pure returns (bool hasThreshold, uint256 thresholdAmount) {
        bytes calldata thresholdData = _getDataSlice(traits, data, TakerDataSlices.Threshold);
        return (thresholdData.length == 32, uint256(bytes32(thresholdData)));
    }

    function to(TakerTraits traits, bytes calldata data, address taker) internal pure returns (address) {
        bytes calldata toData = _getDataSlice(traits, data, TakerDataSlices.To);
        return toData.length == 20 ? address(bytes20(toData)) : taker;
    }

    function deadline(TakerTraits traits, bytes calldata data) internal pure returns (uint40) {
        bytes calldata deadlineData = _getDataSlice(traits, data, TakerDataSlices.Deadline);
        return deadlineData.length == 5 ? uint40(bytes5(deadlineData)) : 0;
    }

    function preTransferInHookData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PreTransferInHook);
    }

    function postTransferInHookData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PostTransferInHook);
    }

    function preTransferOutHookData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PreTransferOutHook);
    }

    function postTransferOutHookData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PostTransferOutHook);
    }

    function preTransferInCallbackData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PreTransferInCallback);
    }

    function preTransferOutCallbackData(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata hookData) {
        return _getDataSlice(traits, data, TakerDataSlices.PreTransferOutCallback);
    }

    function instructionsArgs(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata) {
        return _getDataSlice(traits, data, TakerDataSlices.InstructionsArgs);
    }

    function signature(TakerTraits traits, bytes calldata data) internal pure returns (bytes calldata) {
        return _getDataSlice(traits, data, TakerDataSlices.Signature);
    }

    function _getDataSlice(TakerTraits traits, bytes calldata data, TakerDataSlices slice) private pure returns (bytes calldata) {
        return data.slice(
            _getStartOffset(traits, slice),
            _getStopOffset(traits, slice, data.length),
            TakerTraitsMissingHookData.selector
        );
    }

    function _getStartOffset(TakerTraits traits, TakerDataSlices slice) private pure returns (uint256) {
        unchecked {
            return (slice == TakerDataSlices.Threshold) ? 0 : _getOffset(traits, uint256(slice) - 1);
        }
    }

    function _getStopOffset(TakerTraits traits, TakerDataSlices slice, uint256 dataLength) private pure returns (uint256) {
        return (slice == TakerDataSlices.Signature) ? dataLength : _getOffset(traits, uint256(slice));
    }

    function _getOffset(TakerTraits traits, uint256 sliceNumber) private pure returns (uint256) {
        uint256 bitShift = (sliceNumber << TAKER_DATA_SLICES_INDEX_BIT_SIZE_SHL);
        return (TakerTraits.unwrap(traits) >> TAKER_DATA_SLICES_INDEXES_BIT_OFFSET >> bitShift) & TAKER_DATA_SLICES_INDEX_BIT_MAP;
    }
}
