// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Vm } from "forge-std/Vm.sol";
import { MakerTraitsLib } from "src/libs/MakerTraits.sol";
import { ISwapVM } from "src/interfaces/ISwapVM.sol";

library OrderBuilder {
    error SigningAquaOrder();

    enum Hook {
        PreTransferIn,
        PostTransferIn,
        PreTransferOut,
        PostTransferOut
    }

    function init(address maker, TokenMock tokenA, TokenMock tokenB) internal pure returns (MakerTraitsLib.Args memory) {
        return MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
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
            program: ""
        });
    }

    function unwrapWeth(MakerTraitsLib.Args memory args) internal pure returns (MakerTraitsLib.Args memory) {
        args.shouldUnwrapWeth = true;
        return args;
    }

    function enableAqua(MakerTraitsLib.Args memory args) internal pure returns (MakerTraitsLib.Args memory) {
        args.useAquaInsteadOfSignature = true;
        return args;
    }

    function allowZeroIn(MakerTraitsLib.Args memory args) internal pure returns (MakerTraitsLib.Args memory) {
        args.allowZeroAmountIn = true;
        return args;
    }

    function sendTo(MakerTraitsLib.Args memory args, address target) internal pure returns (MakerTraitsLib.Args memory) {
        args.receiver = target;
        return args;
    }

    function setHook(MakerTraitsLib.Args memory args, Hook id, address target, bytes memory data) internal pure returns (MakerTraitsLib.Args memory) {
        if (id == Hook.PreTransferIn) {
            args.hasPreTransferInHook = true;
            args.preTransferInTarget = target;
            args.preTransferInData = data;
        } else if (id == Hook.PostTransferIn) {
            args.hasPostTransferInHook = true;
            args.postTransferInTarget = target;
            args.postTransferInData = data;
        } else if (id == Hook.PreTransferOut) {
            args.hasPreTransferOutHook = true;
            args.preTransferOutTarget = target;
            args.preTransferOutData = data;
        } else if (id == Hook.PostTransferOut) {
            args.hasPostTransferOutHook = true;
            args.postTransferOutTarget = target;
            args.postTransferOutData = data;
        }
        return args;
    }

    function setHook(MakerTraitsLib.Args memory args, Hook id, bytes memory data) internal pure returns (MakerTraitsLib.Args memory) {
        return setHook(args, id, address(0), data);
    }

    function setProgram(MakerTraitsLib.Args memory args, bytes memory data) internal pure returns (MakerTraitsLib.Args memory) {
        args.program = data;
        return args;
    }

    function build(MakerTraitsLib.Args memory args) internal pure returns (ISwapVM.Order memory order) {
        order = MakerTraitsLib.build(args);
    }

    function build(MakerTraitsLib.Args memory args, Vm vm, ISwapVM swapVM, uint256 key) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        require(!args.useAquaInsteadOfSignature, SigningAquaOrder());
        order = MakerTraitsLib.build(args);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, swapVM.hash(order));
        signature = abi.encodePacked(r, s, v);
    }
}
