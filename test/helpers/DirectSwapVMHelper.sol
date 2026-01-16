// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "../utils/Dynamic.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";

import { ISwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { Controls, ControlsArgsBuilder } from "../../src/instructions/Controls.sol";

/// @title Helper contract for Direct (signature-based) SwapVM with OpcodesDebug
contract DirectSwapVMHelper is OpcodesDebug {
    using ProgramBuilder for Program;

    SwapVMRouter public router;
    Vm internal vmInstance;

    constructor(address aqua, Vm _vm) OpcodesDebug(aqua) {
        router = new SwapVMRouter(aqua, address(0), "SwapVM", "1.0.0");
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
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([balanceA, balanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt, ControlsArgsBuilder.buildSalt(uint64(uint256(keccak256(abi.encode(block.timestamp))))))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
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
