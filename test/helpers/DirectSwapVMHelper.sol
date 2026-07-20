// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { ISwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { Salt } from "../../src/instructions/Controls.sol";

/// @title Helper contract for Direct (signature-based) SwapVM with OpcodesDebug
contract DirectSwapVMHelper is OpcodesDebug {
    SwapVMRouter public router;
    Vm internal vmInstance;

    constructor(address aqua, Vm _vm) {
        router = new SwapVMRouter(aqua, address(0), address(this), "SwapVM", "1.0.0");
        vmInstance = _vm;
    }

    function createSignedOrder(
        address maker,
        uint256 makerPrivateKey,
        TokenMock tokenA,
        TokenMock tokenB,
        uint256 balanceA,
        uint256 balanceB
    ) external view returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            StaticBalances.build(balanceA, balanceB),
            LimitSwap.build(address(tokenB), address(tokenA)),
            Salt.build(uint64(uint256(keccak256(abi.encode(block.timestamp)))))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        bytes32 orderHash = router.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vmInstance.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }
}
