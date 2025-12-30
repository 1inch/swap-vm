// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { TakerTraits, TakerTraitsLib } from "./TakerTraits.sol";
import { IMakerHooks } from "../interfaces/IMakerHooks.sol";
import { ISwapVM } from "../interfaces/ISwapVM.sol";

type MakerTraits is uint256;

library MakerTraitsLib {
    using SafeCast for uint256;
    using Calldata for bytes;
    using TakerTraitsLib for TakerTraits;
    using MakerTraitsLib for MakerTraits;

    error MakerTraitsMissingHookData();
    error MakerTraitsMissingHookTarget();
    error MakerTraitsMissingProgramData();
    error MakerTraitsMissingHasPreTransferInFlag();
    error MakerTraitsMissingHasPostTransferInFlag();
    error MakerTraitsMissingHasPreTransferOutFlag();
    error MakerTraitsMissingHasPostTransferOutFlag();
    error MakerTraitsTokenInAndTokenOutMustBeDifferent();
    error MakerTraitsZeroAmountInNotAllowed();

    uint256 constant internal SHOULD_UNWRAP_BIT_FLAG = 1 << 255;
    uint256 constant internal USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG = 1 << 254;
    uint256 constant internal ALLOW_ZERO_AMOUNT_IN = 1 << 253;
    uint256 constant internal HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG = 1 << 252;
    uint256 constant internal HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG = 1 << 251;
    uint256 constant internal HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG = 1 << 250;
    uint256 constant internal HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG = 1 << 249;
    uint256 constant internal PRE_TRANSFER_IN_HOOK_HAS_TARGET = 1 << 248;
    uint256 constant internal POST_TRANSFER_IN_HOOK_HAS_TARGET = 1 << 247;
    uint256 constant internal PRE_TRANSFER_OUT_HOOK_HAS_TARGET = 1 << 246;
    uint256 constant internal POST_TRANSFER_OUT_HOOK_HAS_TARGET = 1 << 245;

    uint256 constant internal ORDER_DATA_SLICES_INDEXES_BIT_OFFSET = 160;
    uint256 constant internal ORDER_DATA_SLICES_INDEXES_BIT_MASK = type(uint64).max;
    uint256 constant internal ORDER_DATA_SLICES_INDEX_BIT_MASK = type(uint16).max;
    uint256 constant internal ORDER_DATA_SLICES_INDEX_BIT_SIZE_SHL = 4;

    enum OrderDataSlices {
        PreTransferInHook,
        PostTransferInHook,
        PreTransferOutHook,
        PostTransferOutHook,
        Program
    }

    struct Args {
        address maker;
        address receiver;
        bool shouldUnwrapWeth;
        bool useAquaInsteadOfSignature;
        bool allowZeroAmountIn;
        bool hasPreTransferInHook;
        bool hasPostTransferInHook;
        bool hasPreTransferOutHook;
        bool hasPostTransferOutHook;

        address preTransferInTarget;
        bytes preTransferInData;
        address postTransferInTarget;
        bytes postTransferInData;
        address preTransferOutTarget;
        bytes preTransferOutData;
        address postTransferOutTarget;
        bytes postTransferOutData;
        bytes program;
    }

    function build(Args memory args) internal pure returns (ISwapVM.Order memory order) {
        bool preTransferInHasTarget = args.preTransferInTarget != args.maker && args.preTransferInTarget != address(0);
        bool postTransferInHasTarget = args.postTransferInTarget != args.maker && args.postTransferInTarget != address(0);
        bool preTransferOutHasTarget = args.preTransferOutTarget != args.maker && args.preTransferOutTarget != address(0);
        bool postTransferOutHasTarget = args.postTransferOutTarget != args.maker && args.postTransferOutTarget != address(0);
        if (preTransferInHasTarget || args.preTransferInData.length > 0) {
            require(args.hasPreTransferInHook, MakerTraitsMissingHasPreTransferInFlag());
        }
        if (postTransferInHasTarget || args.postTransferInData.length > 0) {
            require(args.hasPostTransferInHook, MakerTraitsMissingHasPostTransferInFlag());
        }
        if (preTransferOutHasTarget || args.preTransferOutData.length > 0) {
            require(args.hasPreTransferOutHook, MakerTraitsMissingHasPreTransferOutFlag());
        }
        if (postTransferOutHasTarget || args.postTransferOutData.length > 0) {
            require(args.hasPostTransferOutHook, MakerTraitsMissingHasPostTransferOutFlag());
        }

        uint256 index0 = ((preTransferInHasTarget ? 20 : 0) + args.preTransferInData.length).toUint16();
        uint256 index1 = (index0 + (postTransferInHasTarget ? 20 : 0) + args.postTransferInData.length).toUint16();
        uint256 index2 = (index1 + (preTransferOutHasTarget ? 20 : 0) + args.preTransferOutData.length).toUint16();
        uint256 index3 = (index2 + (postTransferOutHasTarget ? 20 : 0) + args.postTransferOutData.length).toUint16();

        uint64 orderDataIndexes = (
            (uint64(index0) << 0) |
            (uint64(index1) << 16) |
            (uint64(index2) << 32) |
            (uint64(index3) << 48)
        );

        return ISwapVM.Order({
            maker: args.maker,
            traits: MakerTraits.wrap(
                (args.shouldUnwrapWeth ? SHOULD_UNWRAP_BIT_FLAG : 0) |
                (args.useAquaInsteadOfSignature ? USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG : 0) |
                (args.allowZeroAmountIn ? ALLOW_ZERO_AMOUNT_IN : 0) |
                (args.hasPreTransferInHook ? HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG : 0) |
                (args.hasPostTransferInHook ? HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG : 0) |
                (args.hasPreTransferOutHook ? HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG : 0) |
                (args.hasPostTransferOutHook ? HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG : 0) |
                (preTransferInHasTarget ? PRE_TRANSFER_IN_HOOK_HAS_TARGET : 0) |
                (postTransferInHasTarget ? POST_TRANSFER_IN_HOOK_HAS_TARGET : 0) |
                (preTransferOutHasTarget ? PRE_TRANSFER_OUT_HOOK_HAS_TARGET : 0) |
                (postTransferOutHasTarget ? POST_TRANSFER_OUT_HOOK_HAS_TARGET : 0) |
                (uint256(orderDataIndexes) << ORDER_DATA_SLICES_INDEXES_BIT_OFFSET) |
                uint160(args.receiver)
            ),
            data: bytes.concat(
                preTransferInHasTarget ? abi.encodePacked(args.preTransferInTarget) : bytes(""),
                args.preTransferInData,
                postTransferInHasTarget ? abi.encodePacked(args.postTransferInTarget) : bytes(""),
                args.postTransferInData,
                preTransferOutHasTarget ? abi.encodePacked(args.preTransferOutTarget) : bytes(""),
                args.preTransferOutData,
                postTransferOutHasTarget ? abi.encodePacked(args.postTransferOutTarget) : bytes(""),
                args.postTransferOutData,
                args.program
            )
        });
    }

    function validate(MakerTraits traits, address tokenIn, address tokenOut, uint256 amountIn) internal pure {
        require(tokenIn != tokenOut, MakerTraitsTokenInAndTokenOutMustBeDifferent());
        require(amountIn > 0 || traits.allowZeroAmountIn(), MakerTraitsZeroAmountInNotAllowed());
    }

    function shouldUnwrapWeth(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & SHOULD_UNWRAP_BIT_FLAG) != 0;
    }

    function useAquaInsteadOfSignature(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG) != 0;
    }

    function allowZeroAmountIn(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & ALLOW_ZERO_AMOUNT_IN) != 0;
    }

    function hasPreTransferInHook(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG) != 0;
    }

    function hasPostTransferInHook(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG) != 0;
    }

    function hasPreTransferOutHook(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG) != 0;
    }

    function hasPostTransferOutHook(MakerTraits traits) internal pure returns (bool) {
        return (MakerTraits.unwrap(traits) & HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG) != 0;
    }

    function receiver(MakerTraits traits, address maker) internal pure returns (address) {
        address to = address(uint160(MakerTraits.unwrap(traits)));
        return to == address(0) ? maker : to;
    }

    // Slices getters

    function program(MakerTraits traits, bytes calldata data) internal pure returns (bytes calldata) {
        return _getDataSlice(traits, data, OrderDataSlices.Program);
    }

    function preTransferInHook(MakerTraits traits, address maker, bytes calldata data) internal pure returns (IMakerHooks target, bytes calldata hookData) {
        return _getDataSliceWithTarget(traits, maker, data, OrderDataSlices.PreTransferInHook, PRE_TRANSFER_IN_HOOK_HAS_TARGET);
    }

    function postTransferInHook(MakerTraits traits, address maker, bytes calldata data) internal pure returns (IMakerHooks target, bytes calldata hookData) {
        return _getDataSliceWithTarget(traits, maker, data, OrderDataSlices.PostTransferInHook, POST_TRANSFER_IN_HOOK_HAS_TARGET);
    }

    function preTransferOutHook(MakerTraits traits, address maker, bytes calldata data) internal pure returns (IMakerHooks target, bytes calldata hookData) {
        return _getDataSliceWithTarget(traits, maker, data, OrderDataSlices.PreTransferOutHook, PRE_TRANSFER_OUT_HOOK_HAS_TARGET);
    }

    function postTransferOutHook(MakerTraits traits, address maker, bytes calldata data) internal pure returns (IMakerHooks target, bytes calldata hookData) {
        return _getDataSliceWithTarget(traits, maker, data, OrderDataSlices.PostTransferOutHook, POST_TRANSFER_OUT_HOOK_HAS_TARGET);
    }

    function _getDataSliceWithTarget(MakerTraits traits, address maker, bytes calldata data, OrderDataSlices slice, uint256 bitFlag) private pure returns (IMakerHooks target, bytes calldata hookData) {
        hookData = _getDataSlice(traits, data, slice);

        if ((MakerTraits.unwrap(traits) & bitFlag) != 0) {
            target = IMakerHooks(address(bytes20(hookData.slice(0, 20, MakerTraitsMissingHookTarget.selector))));
            hookData = hookData.slice(20);
        } else {
            target = IMakerHooks(maker);
        }
    }

    function _getDataSlice(MakerTraits traits, bytes calldata data, OrderDataSlices slice) private pure returns (bytes calldata) {
        return data.slice(
            _getStartOffset(traits, slice),
            _getStopOffset(traits, slice, data.length),
            MakerTraitsMissingHookData.selector
        );
    }

    function _getStartOffset(MakerTraits traits, OrderDataSlices slice) private pure returns (uint256) {
        unchecked {
            return (slice == OrderDataSlices.PreTransferInHook) ? 0 : _getOffset(traits, uint256(slice) - 1);
        }
    }

    function _getStopOffset(MakerTraits traits, OrderDataSlices slice, uint256 dataLength) private pure returns (uint256) {
        return (slice == OrderDataSlices.Program) ? dataLength : _getOffset(traits, uint256(slice));
    }

    function _getOffset(MakerTraits traits, uint256 sliceNumber) private pure returns (uint256) {
        uint256 bitShift = (sliceNumber << ORDER_DATA_SLICES_INDEX_BIT_SIZE_SHL);
        return (MakerTraits.unwrap(traits) >> ORDER_DATA_SLICES_INDEXES_BIT_OFFSET >> bitShift) & ORDER_DATA_SLICES_INDEX_BIT_MASK;
    }
}
