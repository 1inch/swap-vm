// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";

library TakerBuilder {
    enum Hook {
        PreTransferIn,
        PostTransferIn,
        PreTransferOut,
        PostTransferOut
    }

    enum Callback {
        PreTransferIn,
        PreTransferOut
    }

    function init(address taker, bool isExactIn, bool isAToB) internal pure returns (TakerTraitsLib.Args memory) {
        return TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: isAToB,
            allowPartialFill: true,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        });
    }

    function unwrapWeth(TakerTraitsLib.Args memory args) internal pure returns (TakerTraitsLib.Args memory) {
        args.shouldUnwrapWeth = true;
        return args;
    }

    function takerSpendFirst(TakerTraitsLib.Args memory args) internal pure returns (TakerTraitsLib.Args memory) {
        args.isFirstTransferFromTaker = true;
        return args;
    }

    function callbackAquaPush(TakerTraitsLib.Args memory args) internal pure returns (TakerTraitsLib.Args memory) {
        args.useTransferFromAndAquaPush = false;
        return args;
    }

    function strictTakerAmount(TakerTraitsLib.Args memory args) internal pure returns (TakerTraitsLib.Args memory) {
        args.allowPartialFill = false;
        return args;
    }

    function setThreshold(TakerTraitsLib.Args memory args, uint256 value, bool strict) internal pure returns (TakerTraitsLib.Args memory) {
        args.threshold = abi.encodePacked(value);
        args.isStrictThresholdAmount = strict;
        return args;
    }

    function setThreshold(TakerTraitsLib.Args memory args, uint256 value) internal pure returns (TakerTraitsLib.Args memory) {
        return setThreshold(args, value, false);
    }

    function sendTo(TakerTraitsLib.Args memory args, address target) internal pure returns (TakerTraitsLib.Args memory) {
        args.to = target;
        return args;
    }

    function setDeadline(TakerTraitsLib.Args memory args, uint40 ts) internal pure returns (TakerTraitsLib.Args memory) {
        args.deadline = ts;
        return args;
    }

    function setHook(TakerTraitsLib.Args memory args, Hook id, bytes memory data) internal pure returns (TakerTraitsLib.Args memory) {
        if (id == Hook.PreTransferIn) {
            args.preTransferInHookData = data;
        } else if (id == Hook.PostTransferIn) {
            args.postTransferInHookData = data;
        } else if (id == Hook.PreTransferOut) {
            args.preTransferOutHookData = data;
        } else if (id == Hook.PostTransferOut) {
            args.postTransferOutHookData = data;
        }
        return args;
    }

    function setCallback(TakerTraitsLib.Args memory args, Callback id, bytes memory data) internal pure returns (TakerTraitsLib.Args memory) {
        if (id == Callback.PreTransferIn) {
            args.hasPreTransferInCallback = true;
            args.preTransferInCallbackData = data;
        } else if (id == Callback.PreTransferOut) {
            args.hasPreTransferOutCallback = true;
            args.preTransferOutCallbackData = data;
        }
        return args;
    }

    function setTakerArgs(TakerTraitsLib.Args memory args, bytes memory data) internal pure returns (TakerTraitsLib.Args memory) {
        args.instructionsArgs = data;
        return args;
    }

    function build(TakerTraitsLib.Args memory args) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(args);
    }
}
