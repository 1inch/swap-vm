// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../contracts/libs/TakerTraits.sol";

/// @dev Deployed via `DeployCode.TraitsHelper()`. Tests must not import this file.
contract TraitsHelper {
    struct MakerTraitsLibArgs {
        address maker;
        address receiver;
        address tokenA;
        address tokenB;
        bool shouldUnwrapWeth;
        bool useAquaInsteadOfSignature;
        bool allowZeroAmountIn;
        bytes program;
    }

    struct TakerTraitsLibArgs {
        address taker;
        bool isExactIn;
        bool shouldUnwrapWeth;
        bool isFirstTransferFromTaker;
        bool useTransferFromAndAquaPush;
        bool isAToB;
        bool allowPartialFill;
        bytes threshold;
        address to;
        bool hasPreTransferInCallback;
        bytes signature;
    }

    function MakerTraitsLibBuild(MakerTraitsLibArgs calldata args) external pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: args.maker,
            receiver: args.receiver,
            tokenA: args.tokenA,
            tokenB: args.tokenB,
            shouldUnwrapWeth: args.shouldUnwrapWeth,
            useAquaInsteadOfSignature: args.useAquaInsteadOfSignature,
            allowZeroAmountIn: args.allowZeroAmountIn,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: args.program
        }));
    }

    function TakerTraitsLibBuild(TakerTraitsLibArgs calldata args) external pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: args.taker,
            isExactIn: args.isExactIn,
            shouldUnwrapWeth: args.shouldUnwrapWeth,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: args.isFirstTransferFromTaker,
            useTransferFromAndAquaPush: args.useTransferFromAndAquaPush,
            isAToB: args.isAToB,
            allowPartialFill: args.allowPartialFill,
            threshold: args.threshold,
            to: args.to,
            deadline: 0,
            hasPreTransferInCallback: args.hasPreTransferInCallback,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: args.signature
        }));
    }
}
