// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { MockMakerHooks } from "./mocks/MockMakerHooks.sol";

contract MakerHooksTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    MockMakerHooks public hooksContract;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Deploy hooks contract
        hooksContract = new MockMakerHooks();

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_MakerHooksWithTakerData() public {
        // === Setup ===
        uint256 makerBalanceA = 100e18;
        uint256 makerBalanceB = 200e18;

        // Prepare hook data
        bytes memory makerPreInData = abi.encodePacked("MAKER_PRE_IN_DATA");
        bytes memory makerPostInData = abi.encodePacked("MAKER_POST_IN_DATA");
        bytes memory makerPreOutData = abi.encodePacked("MAKER_PRE_OUT_DATA");
        bytes memory makerPostOutData = abi.encodePacked("MAKER_POST_OUT_DATA");

        bytes memory takerPreInData = abi.encodePacked("TAKER_PRE_IN_DATA");
        bytes memory takerPostInData = abi.encodePacked("TAKER_POST_IN_DATA");
        bytes memory takerPreOutData = abi.encodePacked("TAKER_PRE_OUT_DATA");
        bytes memory takerPostOutData = abi.encodePacked("TAKER_POST_OUT_DATA");

        // === Build Program ===
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0x9876))
        );

        // === Create Order with Hooks ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: true,
            hasPostTransferInHook: true,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: true,
            preTransferInTarget: address(hooksContract),
            preTransferInData: makerPreInData,
            postTransferInTarget: address(hooksContract),
            postTransferInData: makerPostInData,
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: makerPreOutData,
            postTransferOutTarget: address(hooksContract),
            postTransferOutData: makerPostOutData,
            program: programBytes
        }));

        // === Sign Order ===
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // === Create TakerData with Hook Data ===
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "", // min TokenA to receive
            to: address(0), // 0 = taker
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: takerPreInData,
            postTransferInHookData: takerPostInData,
            preTransferOutHookData: takerPreOutData,
            postTransferOutHookData: takerPostOutData,
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        // === Execute Swap ===
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order,
            address(tokenB), // tokenIn
            address(tokenA), // tokenOut
            50e18,           // amount of tokenB to spend
            takerData
        );

        // === Verify Hook Execution ===
        // Check that all hooks were called
        assertTrue(hooksContract.allHooksCalled(), "Not all hooks were called");

        // Verify hook call counts
        assertEq(hooksContract.preTransferInCallCount(), 1, "preTransferIn should be called once");
        assertEq(hooksContract.postTransferInCallCount(), 1, "postTransferIn should be called once");
        assertEq(hooksContract.preTransferOutCallCount(), 1, "preTransferOut should be called once");
        assertEq(hooksContract.postTransferOutCallCount(), 1, "postTransferOut should be called once");

        // === Verify Hook Data - PreTransferIn ===
        (
            address lastMaker,
            address lastTaker,
            address lastTokenIn,
            address lastTokenOut,
            uint256 lastAmountIn,
            uint256 lastAmountOut,
            bytes32 lastOrderHash,
            bytes memory lastMakerData,
            bytes memory lastTakerData
        ) = hooksContract.lastPreTransferIn();

        assertEq(lastMaker, maker, "PreTransferIn: incorrect maker");
        assertEq(lastTaker, taker, "PreTransferIn: incorrect taker");
        assertEq(lastTokenIn, address(tokenB), "PreTransferIn: incorrect tokenIn");
        assertEq(lastTokenOut, address(tokenA), "PreTransferIn: incorrect tokenOut");
        assertEq(lastAmountIn, amountIn, "PreTransferIn: incorrect amountIn");
        assertEq(lastAmountOut, amountOut, "PreTransferIn: incorrect amountOut");
        assertEq(lastOrderHash, orderHash, "PreTransferIn: incorrect orderHash");
        assertEq(lastMakerData, makerPreInData, "PreTransferIn: incorrect maker data");
        assertEq(lastTakerData, takerPreInData, "PreTransferIn: incorrect taker data");

        // === Verify Hook Data - PostTransferIn ===
        (
            lastMaker,
            lastTaker,
            lastTokenIn,
            lastTokenOut,
            lastAmountIn,
            lastAmountOut,
            lastOrderHash,
            lastMakerData,
            lastTakerData
        ) = hooksContract.lastPostTransferIn();

        assertEq(lastMaker, maker, "PostTransferIn: incorrect maker");
        assertEq(lastTaker, taker, "PostTransferIn: incorrect taker");
        assertEq(lastTokenIn, address(tokenB), "PostTransferIn: incorrect tokenIn");
        assertEq(lastTokenOut, address(tokenA), "PostTransferIn: incorrect tokenOut");
        assertEq(lastAmountIn, amountIn, "PostTransferIn: incorrect amountIn");
        assertEq(lastAmountOut, amountOut, "PostTransferIn: incorrect amountOut");
        assertEq(lastOrderHash, orderHash, "PostTransferIn: incorrect orderHash");
        assertEq(lastMakerData, makerPostInData, "PostTransferIn: incorrect maker data");
        assertEq(lastTakerData, takerPostInData, "PostTransferIn: incorrect taker data");

        // === Verify Hook Data - PreTransferOut ===
        (
            lastMaker,
            lastTaker,
            lastTokenIn,
            lastTokenOut,
            lastAmountIn,
            lastAmountOut,
            lastOrderHash,
            lastMakerData,
            lastTakerData
        ) = hooksContract.lastPreTransferOut();

        assertEq(lastMaker, maker, "PreTransferOut: incorrect maker");
        assertEq(lastTaker, taker, "PreTransferOut: incorrect taker");
        assertEq(lastTokenIn, address(tokenB), "PreTransferOut: incorrect tokenIn");
        assertEq(lastTokenOut, address(tokenA), "PreTransferOut: incorrect tokenOut");
        assertEq(lastAmountIn, amountIn, "PreTransferOut: incorrect amountIn");
        assertEq(lastAmountOut, amountOut, "PreTransferOut: incorrect amountOut");
        assertEq(lastOrderHash, orderHash, "PreTransferOut: incorrect orderHash");
        assertEq(lastMakerData, makerPreOutData, "PreTransferOut: incorrect maker data");
        assertEq(lastTakerData, takerPreOutData, "PreTransferOut: incorrect taker data");

        // === Verify Hook Data - PostTransferOut ===
        (
            lastMaker,
            lastTaker,
            lastTokenIn,
            lastTokenOut,
            lastAmountIn,
            lastAmountOut,
            lastOrderHash,
            lastMakerData,
            lastTakerData
        ) = hooksContract.lastPostTransferOut();

        assertEq(lastMaker, maker, "PostTransferOut: incorrect maker");
        assertEq(lastTaker, taker, "PostTransferOut: incorrect taker");
        assertEq(lastTokenIn, address(tokenB), "PostTransferOut: incorrect tokenIn");
        assertEq(lastTokenOut, address(tokenA), "PostTransferOut: incorrect tokenOut");
        assertEq(lastAmountIn, amountIn, "PostTransferOut: incorrect amountIn");
        assertEq(lastAmountOut, amountOut, "PostTransferOut: incorrect amountOut");
        assertEq(lastOrderHash, orderHash, "PostTransferOut: incorrect orderHash");
        assertEq(lastMakerData, makerPostOutData, "PostTransferOut: incorrect maker data");
        assertEq(lastTakerData, takerPostOutData, "PostTransferOut: incorrect taker data");

        // === Verify Swap Results ===
        assertEq(amountIn, 50e18, "Incorrect amountIn");
        assertEq(amountOut, 25e18, "Incorrect amountOut");
        assertEq(tokenA.balanceOf(taker), 25e18, "Incorrect TokenA received");
        assertEq(tokenB.balanceOf(maker), 50e18, "Incorrect TokenB received by maker");
    }

    function test_HooksWithEmptyTakerData() public {
        // === Setup ===
        uint256 makerBalanceA = 100e18;
        uint256 makerBalanceB = 200e18;

        // Prepare hook data (only maker data, no taker data)
        bytes memory makerPreInData = abi.encodePacked("MAKER_DATA");
        bytes memory makerPostInData = abi.encodePacked("MAKER_DATA_2");

        // === Build Program ===
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0x5555))
        );

        // === Create Order with Only Some Hooks ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: true,
            hasPostTransferInHook: true,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(hooksContract),
            preTransferInData: makerPreInData,
            postTransferInTarget: address(hooksContract),
            postTransferInData: makerPostInData,
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes
        }));

        // === Sign Order ===
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // === Create TakerData WITHOUT Hook Data ===
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)),
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "", // Empty taker data
            postTransferInHookData: "", // Empty taker data
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        // Reset hook counters
        hooksContract.resetCounters();

        // === Execute Swap ===
        vm.prank(taker);
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );

        // === Verify Hook Execution ===
        assertEq(hooksContract.preTransferInCallCount(), 1, "preTransferIn should be called");
        assertEq(hooksContract.postTransferInCallCount(), 1, "postTransferIn should be called");
        assertEq(hooksContract.preTransferOutCallCount(), 0, "preTransferOut should not be called");
        assertEq(hooksContract.postTransferOutCallCount(), 0, "postTransferOut should not be called");

        // === Verify Empty Taker Data in Hooks ===
        (,,,,,,, bytes memory lastMakerData, bytes memory lastTakerData) = hooksContract.lastPreTransferIn();
        assertEq(lastMakerData, makerPreInData, "PreTransferIn: incorrect maker data");
        assertEq(lastTakerData.length, 0, "PreTransferIn: taker data should be empty");

        (,,,,,,, lastMakerData, lastTakerData) = hooksContract.lastPostTransferIn();
        assertEq(lastMakerData, makerPostInData, "PostTransferIn: incorrect maker data");
        assertEq(lastTakerData.length, 0, "PostTransferIn: taker data should be empty");
    }

    function test_HooksExecutionOrder() public {
        // This test verifies hooks are called in the correct order
        // Create a special hooks contract that tracks call order

        // === Setup ===
        uint256 makerBalanceA = 100e18;
        uint256 makerBalanceB = 200e18;

        // === Build Program ===
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0x7777))
        );

        // === Create Order with All Hooks ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: true,
            hasPostTransferInHook: true,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: true,
            preTransferInTarget: address(hooksContract),
            preTransferInData: abi.encodePacked("PRE_IN"),
            postTransferInTarget: address(hooksContract),
            postTransferInData: abi.encodePacked("POST_IN"),
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: abi.encodePacked("PRE_OUT"),
            postTransferOutTarget: address(hooksContract),
            postTransferOutData: abi.encodePacked("POST_OUT"),
            program: programBytes
        }));

        // === Sign Order ===
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // === Create TakerData ===
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true, // This means transferIn happens first
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)),
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: abi.encodePacked("TAKER_PRE_IN"),
            postTransferInHookData: abi.encodePacked("TAKER_POST_IN"),
            preTransferOutHookData: abi.encodePacked("TAKER_PRE_OUT"),
            postTransferOutHookData: abi.encodePacked("TAKER_POST_OUT"),
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        // Reset counters
        hooksContract.resetCounters();

        // === Execute Swap and Check Events Order ===
        vm.recordLogs();

        vm.prank(taker);
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find hook events in order
        uint256 preInIndex = type(uint256).max;
        uint256 postInIndex = type(uint256).max;
        uint256 preOutIndex = type(uint256).max;
        uint256 postOutIndex = type(uint256).max;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PreTransferInCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                preInIndex = i;
            }
            if (logs[i].topics[0] == keccak256("PostTransferInCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                postInIndex = i;
            }
            if (logs[i].topics[0] == keccak256("PreTransferOutCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                preOutIndex = i;
            }
            if (logs[i].topics[0] == keccak256("PostTransferOutCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                postOutIndex = i;
            }
        }

        // Verify order when isFirstTransferFromTaker = true:
        // 1. PreTransferIn
        // 2. PostTransferIn
        // 3. PreTransferOut
        // 4. PostTransferOut
        assertTrue(preInIndex < postInIndex, "PreTransferIn should be called before PostTransferIn");
        assertTrue(postInIndex < preOutIndex, "PostTransferIn should be called before PreTransferOut");
        assertTrue(preOutIndex < postOutIndex, "PreTransferOut should be called before PostTransferOut");
    }
}
