// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { SwapRegisters } from "../src/libs/VM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { PrintSwapRegisters, PrintSwapQuery, PrintVM, PrintFreeMemoryPointer, PrintGasLeft, PrintFee, PatchSwapRegisters } from "../src/instructions/Debug.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";
import { FeeBuilders } from "./utils/FeeBuilders.sol";

contract DebugTest is Test {
    SwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant AMOUNT = 1e18;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouterDebug(address(new Aqua()), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(taker, AMOUNT);
        tokenB.mint(maker, AMOUNT);

        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_DebugOpcodes() public {
        bytes memory bytecode = bytes.concat(
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: 123e18,
                balanceOut: 98e18,
                amountIn: AMOUNT,
                amountOut: AMOUNT
            })),
            PrintSwapRegisters.build(),
            PrintSwapQuery.build(),
            PrintVM.build(),
            PrintFreeMemoryPointer.build(),
            PrintGasLeft.build(),
            PrintFee.build(),
            FeeBuilders.protocolSurplusIn(0.4e7, address(this), 123e18)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, AMOUNT, takerData);

        assertEq(amountIn, AMOUNT);
        assertEq(amountOut, AMOUNT);
        assertEq(tokenB.balanceOf(taker), AMOUNT);
        assertEq(tokenA.balanceOf(maker), AMOUNT);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: program
        }));
    }

    function _signAndPackTakerData(ISwapVM.Order memory order) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            isAToB: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(this),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "param pam",
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
