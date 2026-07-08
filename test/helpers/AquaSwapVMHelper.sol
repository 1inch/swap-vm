// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Program, ProgramBuilder, Opcode } from "../utils/ProgramBuilder.sol";

import { ISwapVM } from "../../src/SwapVM.sol";
import { AquaSwapVMRouter } from "../../src/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { AquaOpcodesDebug } from "../../src/opcodes/AquaOpcodesDebug.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Salt } from "../../src/instructions/Controls.sol";

/// @title Helper contract for Aqua SwapVM with AquaOpcodesDebug
contract AquaSwapVMHelper is AquaOpcodesDebug {
    using ProgramBuilder for Program;

    AquaSwapVMRouter public router;

    constructor(address aqua) AquaOpcodesDebug(aqua) {
        router = new AquaSwapVMRouter(aqua, address(0), address(this), "SwapVM", "1.0.0");
    }

    function createOrder(
        address maker,
        TokenMock tokenA,
        TokenMock tokenB
    ) external view returns (ISwapVM.Order memory) {
        Program p;
        bytes memory programBytes = bytes.concat(
            p.build(Opcode.XYCSwap),
            Salt.build(uint64(uint256(keccak256(abi.encode(block.timestamp)))))
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
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
    }
}
