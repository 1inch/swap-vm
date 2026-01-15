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
import { RevertingMakerHooks } from "./mocks/RevertingMakerHooks.sol";

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
        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

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

    function test_PreTransferOutHook_Reverts_SwapReverts() public {
        // Test 1: Reverting preTransferOut hook should revert the entire swap
        RevertingMakerHooks revertingHooks = new RevertingMakerHooks();
        revertingHooks.setRevertOn(RevertingMakerHooks.HookType.PreTransferOut);

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
                ControlsArgsBuilder.buildSalt(0xAAAA))
        );

        // === Create Order with Reverting PreTransferOut Hook ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(revertingHooks),
            preTransferOutData: abi.encodePacked("DATA"),
            postTransferOutTarget: address(0),
            postTransferOutData: "",
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
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
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
            signature: signature
        }));

        // === Expect Revert ===
        vm.prank(taker);
        vm.expectRevert(RevertingMakerHooks.PreTransferOutReverted.selector);
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );
    }

    function test_HooksExecutionOrder_TransferOutFirst() public {
        // Test 2: Verify hook order when isFirstTransferFromTaker = false (transfer out happens first)

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
                ControlsArgsBuilder.buildSalt(0xBBBB))
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

        // === Create TakerData with isFirstTransferFromTaker = false ===
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false, // Transfer out happens first!
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

        // Verify order when isFirstTransferFromTaker = false:
        // 1. PreTransferOut
        // 2. PostTransferOut
        // 3. PreTransferIn
        // 4. PostTransferIn
        assertTrue(preOutIndex < postOutIndex, "PreTransferOut should be called before PostTransferOut");
        assertTrue(postOutIndex < preInIndex, "PostTransferOut should be called before PreTransferIn");
        assertTrue(preInIndex < postInIndex, "PreTransferIn should be called before PostTransferIn");
    }

    function test_DifferentHookTargets_PreTransferOut() public {
        // Test 3: Using different target contracts for different hooks
        MockMakerHooks preInHooks = new MockMakerHooks();
        MockMakerHooks preOutHooks = new MockMakerHooks();

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
                ControlsArgsBuilder.buildSalt(0xCCCC))
        );

        // === Create Order with Different Hook Targets ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: true,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(preInHooks),
            preTransferInData: abi.encodePacked("PRE_IN_DATA"),
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(preOutHooks), // Different target!
            preTransferOutData: abi.encodePacked("PRE_OUT_DATA"),
            postTransferOutTarget: address(0),
            postTransferOutData: "",
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
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: abi.encodePacked("TAKER_PRE_IN"),
            postTransferInHookData: "",
            preTransferOutHookData: abi.encodePacked("TAKER_PRE_OUT"),
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        // === Execute Swap ===
        vm.prank(taker);
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );

        // === Verify Each Target Was Called Correctly ===
        // preInHooks should have preTransferIn called
        assertEq(preInHooks.preTransferInCallCount(), 1, "preInHooks: preTransferIn should be called");
        assertEq(preInHooks.preTransferOutCallCount(), 0, "preInHooks: preTransferOut should NOT be called");

        // preOutHooks should have preTransferOut called
        assertEq(preOutHooks.preTransferOutCallCount(), 1, "preOutHooks: preTransferOut should be called");
        assertEq(preOutHooks.preTransferInCallCount(), 0, "preOutHooks: preTransferIn should NOT be called");

        // Verify data passed to preTransferOut
        (
            address lastMaker,
            address lastTaker,
            address lastTokenIn,
            address lastTokenOut,
            ,
            ,
            bytes32 lastOrderHash,
            bytes memory lastMakerData,
            bytes memory lastTakerData
        ) = preOutHooks.lastPreTransferOut();

        assertEq(lastMaker, maker, "PreTransferOut: incorrect maker");
        assertEq(lastTaker, taker, "PreTransferOut: incorrect taker");
        assertEq(lastTokenIn, address(tokenB), "PreTransferOut: incorrect tokenIn");
        assertEq(lastTokenOut, address(tokenA), "PreTransferOut: incorrect tokenOut");
        assertEq(lastOrderHash, orderHash, "PreTransferOut: incorrect orderHash");
        assertEq(lastMakerData, abi.encodePacked("PRE_OUT_DATA"), "PreTransferOut: incorrect maker data");
        assertEq(lastTakerData, abi.encodePacked("TAKER_PRE_OUT"), "PreTransferOut: incorrect taker data");
    }

    function test_AsymmetricHookData_EmptyMakerNonEmptyTaker() public {
        // Test 4: Empty maker data but non-empty taker data for preTransferOut

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
                ControlsArgsBuilder.buildSalt(0xDDDD))
        );

        // === Create Order with PreTransferOut Hook but EMPTY maker data ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: "", // Empty maker data!
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes
        }));

        // === Sign Order ===
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // === Create TakerData with NON-EMPTY taker hook data ===
        bytes memory takerPreOutData = abi.encodePacked("TAKER_PROVIDED_DATA_FOR_PRE_OUT");
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: takerPreOutData, // Non-empty taker data!
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        // Reset counters
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

        // === Verify Hook Was Called ===
        assertEq(hooksContract.preTransferOutCallCount(), 1, "preTransferOut should be called");

        // === Verify Data ===
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bytes memory lastMakerData,
            bytes memory lastTakerData
        ) = hooksContract.lastPreTransferOut();

        assertEq(lastMakerData.length, 0, "PreTransferOut: maker data should be empty");
        assertEq(lastTakerData, takerPreOutData, "PreTransferOut: taker data should match");
    }

    function test_MultipleConsecutiveSwaps_SameHook() public {
        // Test 5.2: Multiple consecutive swaps using the same hook contract

        // === Setup ===
        uint256 makerBalanceA = 100e18;
        uint256 makerBalanceB = 200e18;

        // Mint extra tokens for multiple swaps
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // === Build Program for first order ===
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes1 = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0xEEE1))
        );

        bytes memory programBytes2 = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0xEEE2))
        );

        bytes memory programBytes3 = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0xEEE3))
        );

        // === Create Three Orders with Same Hook ===
        ISwapVM.Order memory order1 = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: abi.encodePacked("ORDER_1"),
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes1
        }));

        ISwapVM.Order memory order2 = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: abi.encodePacked("ORDER_2"),
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes2
        }));

        ISwapVM.Order memory order3 = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: true,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(hooksContract),
            preTransferOutData: abi.encodePacked("ORDER_3"),
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes3
        }));

        // === Sign Orders ===
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(makerPrivateKey, swapVM.hash(order1));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(makerPrivateKey, swapVM.hash(order2));
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(makerPrivateKey, swapVM.hash(order3));

        // Reset counters
        hooksContract.resetCounters();

        // === Execute First Swap ===
        bytes memory takerData1 = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: abi.encodePacked("SWAP_1"),
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: abi.encodePacked(r1, s1, v1)
        }));

        vm.prank(taker);
        swapVM.swap(order1, address(tokenB), address(tokenA), 10e18, takerData1);

        assertEq(hooksContract.preTransferOutCallCount(), 1, "After swap 1: count should be 1");
        (,,,,,,,bytes memory lastMakerData,) = hooksContract.lastPreTransferOut();
        assertEq(lastMakerData, abi.encodePacked("ORDER_1"), "After swap 1: incorrect maker data");

        // === Execute Second Swap ===
        bytes memory takerData2 = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: abi.encodePacked("SWAP_2"),
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: abi.encodePacked(r2, s2, v2)
        }));

        vm.prank(taker);
        swapVM.swap(order2, address(tokenB), address(tokenA), 20e18, takerData2);

        assertEq(hooksContract.preTransferOutCallCount(), 2, "After swap 2: count should be 2");
        (,,,,,,,lastMakerData,) = hooksContract.lastPreTransferOut();
        assertEq(lastMakerData, abi.encodePacked("ORDER_2"), "After swap 2: incorrect maker data");

        // === Execute Third Swap ===
        bytes memory takerData3 = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: abi.encodePacked("SWAP_3"),
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: abi.encodePacked(r3, s3, v3)
        }));

        vm.prank(taker);
        swapVM.swap(order3, address(tokenB), address(tokenA), 15e18, takerData3);

        assertEq(hooksContract.preTransferOutCallCount(), 3, "After swap 3: count should be 3");
        (,,,,,,,lastMakerData,) = hooksContract.lastPreTransferOut();
        assertEq(lastMakerData, abi.encodePacked("ORDER_3"), "After swap 3: incorrect maker data");
    }
}
