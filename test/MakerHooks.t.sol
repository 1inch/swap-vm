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

    // ==================== Configuration Structs ====================

    struct HookTargets {
        address preIn;
        address postIn;
        address preOut;
        address postOut;
    }

    struct HookData {
        bytes preIn;
        bytes postIn;
        bytes preOut;
        bytes postOut;
    }

    struct TakerConfig {
        bool isFirstTransferFromTaker;
        bool useTransferFromAndAquaPush;
        bytes threshold;
        HookData hookData;
    }

    // ==================== Setup ====================

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        hooksContract = new MockMakerHooks();

        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ==================== Helper Functions ====================

    function _buildProgram(uint64 salt) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([uint256(100e18), uint256(200e18)]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(salt))
        );
    }

    function _buildOrder(
        HookTargets memory targets,
        HookData memory data,
        uint64 salt
    ) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: targets.preIn != address(0),
            hasPostTransferInHook: targets.postIn != address(0),
            hasPreTransferOutHook: targets.preOut != address(0),
            hasPostTransferOutHook: targets.postOut != address(0),
            preTransferInTarget: targets.preIn,
            preTransferInData: data.preIn,
            postTransferInTarget: targets.postIn,
            postTransferInData: data.postIn,
            preTransferOutTarget: targets.preOut,
            preTransferOutData: data.preOut,
            postTransferOutTarget: targets.postOut,
            postTransferOutData: data.postOut,
            program: _buildProgram(salt)
        }));
    }

    function _signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _buildTakerData(TakerConfig memory cfg, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: cfg.isFirstTransferFromTaker,
            useTransferFromAndAquaPush: cfg.useTransferFromAndAquaPush,
            threshold: cfg.threshold,
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: cfg.hookData.preIn,
            postTransferInHookData: cfg.hookData.postIn,
            preTransferOutHookData: cfg.hookData.preOut,
            postTransferOutHookData: cfg.hookData.postOut,
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }

    function _defaultTakerConfig() internal pure returns (TakerConfig memory) {
        return TakerConfig({
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            hookData: HookData("", "", "", "")
        });
    }

    function _allHooksTarget(address target) internal pure returns (HookTargets memory) {
        return HookTargets(target, target, target, target);
    }

    function _executeSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        vm.prank(taker);
        (amountIn, amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), amount, takerData);
    }

    // ==================== Tests ====================

    function test_MakerHooksWithTakerData() public {
        HookData memory makerData = HookData(
            abi.encodePacked("MAKER_PRE_IN_DATA"),
            abi.encodePacked("MAKER_POST_IN_DATA"),
            abi.encodePacked("MAKER_PRE_OUT_DATA"),
            abi.encodePacked("MAKER_POST_OUT_DATA")
        );

        HookData memory takerHookData = HookData(
            abi.encodePacked("TAKER_PRE_IN_DATA"),
            abi.encodePacked("TAKER_POST_IN_DATA"),
            abi.encodePacked("TAKER_PRE_OUT_DATA"),
            abi.encodePacked("TAKER_POST_OUT_DATA")
        );

        ISwapVM.Order memory order = _buildOrder(
            _allHooksTarget(address(hooksContract)),
            makerData,
            0x9876
        );

        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _signOrder(order);

        TakerConfig memory cfg = TakerConfig({
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            hookData: takerHookData
        });

        bytes memory takerData = _buildTakerData(cfg, signature);

        (uint256 amountIn, uint256 amountOut) = _executeSwap(order, 50e18, takerData);

        // Verify all hooks were called
        assertTrue(hooksContract.allHooksCalled(), "Not all hooks were called");
        assertEq(hooksContract.preTransferInCallCount(), 1);
        assertEq(hooksContract.postTransferInCallCount(), 1);
        assertEq(hooksContract.preTransferOutCallCount(), 1);
        assertEq(hooksContract.postTransferOutCallCount(), 1);

        // Verify PreTransferIn data
        _verifyHookData(hooksContract.lastPreTransferIn, orderHash, amountIn, amountOut,
            makerData.preIn, takerHookData.preIn, "PreTransferIn");

        // Verify PostTransferIn data
        _verifyHookData(hooksContract.lastPostTransferIn, orderHash, amountIn, amountOut,
            makerData.postIn, takerHookData.postIn, "PostTransferIn");

        // Verify PreTransferOut data
        _verifyHookData(hooksContract.lastPreTransferOut, orderHash, amountIn, amountOut,
            makerData.preOut, takerHookData.preOut, "PreTransferOut");

        // Verify PostTransferOut data
        _verifyHookData(hooksContract.lastPostTransferOut, orderHash, amountIn, amountOut,
            makerData.postOut, takerHookData.postOut, "PostTransferOut");

        // Verify swap results
        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
        assertEq(tokenA.balanceOf(taker), 25e18);
        assertEq(tokenB.balanceOf(maker), 50e18);
    }

    function _verifyHookData(
        function() external view returns (address, address, address, address, uint256, uint256, bytes32, bytes memory, bytes memory) hookGetter,
        bytes32 expectedOrderHash,
        uint256 expectedAmountIn,
        uint256 expectedAmountOut,
        bytes memory expectedMakerData,
        bytes memory expectedTakerData,
        string memory hookName
    ) internal view {
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
        ) = hookGetter();

        assertEq(lastMaker, maker, string.concat(hookName, ": incorrect maker"));
        assertEq(lastTaker, taker, string.concat(hookName, ": incorrect taker"));
        assertEq(lastTokenIn, address(tokenB), string.concat(hookName, ": incorrect tokenIn"));
        assertEq(lastTokenOut, address(tokenA), string.concat(hookName, ": incorrect tokenOut"));
        assertEq(lastAmountIn, expectedAmountIn, string.concat(hookName, ": incorrect amountIn"));
        assertEq(lastAmountOut, expectedAmountOut, string.concat(hookName, ": incorrect amountOut"));
        assertEq(lastOrderHash, expectedOrderHash, string.concat(hookName, ": incorrect orderHash"));
        assertEq(lastMakerData, expectedMakerData, string.concat(hookName, ": incorrect maker data"));
        assertEq(lastTakerData, expectedTakerData, string.concat(hookName, ": incorrect taker data"));
    }

    function test_HooksWithEmptyTakerData() public {
        HookData memory makerData = HookData(
            abi.encodePacked("MAKER_DATA"),
            abi.encodePacked("MAKER_DATA_2"),
            "",
            ""
        );

        ISwapVM.Order memory order = _buildOrder(
            HookTargets(address(hooksContract), address(hooksContract), address(0), address(0)),
            makerData,
            0x5555
        );

        TakerConfig memory cfg = _defaultTakerConfig();
        cfg.threshold = abi.encodePacked(uint256(25e18));

        hooksContract.resetCounters();
        _executeSwap(order, 50e18, _buildTakerData(cfg, _signOrder(order)));

        assertEq(hooksContract.preTransferInCallCount(), 1);
        assertEq(hooksContract.postTransferInCallCount(), 1);
        assertEq(hooksContract.preTransferOutCallCount(), 0);
        assertEq(hooksContract.postTransferOutCallCount(), 0);

        (,,,,,,, bytes memory lastMakerData, bytes memory lastTakerData) = hooksContract.lastPreTransferIn();
        assertEq(lastMakerData, makerData.preIn);
        assertEq(lastTakerData.length, 0);

        (,,,,,,, lastMakerData, lastTakerData) = hooksContract.lastPostTransferIn();
        assertEq(lastMakerData, makerData.postIn);
        assertEq(lastTakerData.length, 0);
    }

    function test_HooksExecutionOrder() public {
        _testHooksExecutionOrder(true);
    }

    function test_HooksExecutionOrder_TransferOutFirst() public {
        _testHooksExecutionOrder(false);
    }

    function _testHooksExecutionOrder(bool isFirstTransferFromTaker) internal {
        HookData memory makerData = HookData(
            abi.encodePacked("PRE_IN"),
            abi.encodePacked("POST_IN"),
            abi.encodePacked("PRE_OUT"),
            abi.encodePacked("POST_OUT")
        );

        ISwapVM.Order memory order = _buildOrder(
            _allHooksTarget(address(hooksContract)),
            makerData,
            isFirstTransferFromTaker ? 0x7777 : 0xBBBB
        );

        TakerConfig memory cfg = TakerConfig({
            isFirstTransferFromTaker: isFirstTransferFromTaker,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)),
            hookData: HookData(
                abi.encodePacked("TAKER_PRE_IN"),
                abi.encodePacked("TAKER_POST_IN"),
                abi.encodePacked("TAKER_PRE_OUT"),
                abi.encodePacked("TAKER_POST_OUT")
            )
        });

        hooksContract.resetCounters();
        vm.recordLogs();

        _executeSwap(order, 50e18, _buildTakerData(cfg, _signOrder(order)));

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 preInIndex = type(uint256).max;
        uint256 postInIndex = type(uint256).max;
        uint256 preOutIndex = type(uint256).max;
        uint256 postOutIndex = type(uint256).max;

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("PreTransferInCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                preInIndex = i;
            } else if (topic == keccak256("PostTransferInCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                postInIndex = i;
            } else if (topic == keccak256("PreTransferOutCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                preOutIndex = i;
            } else if (topic == keccak256("PostTransferOutCalled(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)")) {
                postOutIndex = i;
            }
        }

        if (isFirstTransferFromTaker) {
            // Order: PreIn -> PostIn -> PreOut -> PostOut
            assertTrue(preInIndex < postInIndex);
            assertTrue(postInIndex < preOutIndex);
            assertTrue(preOutIndex < postOutIndex);
        } else {
            // Order: PreOut -> PostOut -> PreIn -> PostIn
            assertTrue(preOutIndex < postOutIndex);
            assertTrue(postOutIndex < preInIndex);
            assertTrue(preInIndex < postInIndex);
        }
    }

    function test_PreTransferOutHook_Reverts_SwapReverts() public {
        _testRevertingHook(RevertingMakerHooks.HookType.PreTransferOut, RevertingMakerHooks.PreTransferOutReverted.selector);
    }

    function test_PostTransferInHook_Reverts_SwapReverts() public {
        _testRevertingHook(RevertingMakerHooks.HookType.PostTransferIn, RevertingMakerHooks.PostTransferInReverted.selector);
    }

    function _testRevertingHook(RevertingMakerHooks.HookType hookType, bytes4 expectedError) internal {
        RevertingMakerHooks revertingHooks = new RevertingMakerHooks();
        revertingHooks.setRevertOn(hookType);

        HookTargets memory targets;
        HookData memory makerData;

        if (hookType == RevertingMakerHooks.HookType.PreTransferOut) {
            targets = HookTargets(address(0), address(0), address(revertingHooks), address(0));
            makerData = HookData("", "", abi.encodePacked("DATA"), "");
        } else if (hookType == RevertingMakerHooks.HookType.PostTransferIn) {
            targets = HookTargets(address(0), address(revertingHooks), address(0), address(0));
            makerData = HookData("", abi.encodePacked("DATA"), "", "");
        }

        ISwapVM.Order memory order = _buildOrder(targets, makerData, 0xAAAA);

        bytes memory takerData = _buildTakerData(_defaultTakerConfig(), _signOrder(order));

        vm.prank(taker);
        vm.expectRevert(expectedError);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);
    }

    function test_DifferentHookTargets_PreTransferOut() public {
        _testDifferentHookTargets(false);
    }

    function test_DifferentHookTargets_PostTransferIn() public {
        _testDifferentHookTargets(true);
    }

    function _testDifferentHookTargets(bool testPostIn) internal {
        MockMakerHooks hooks1 = new MockMakerHooks();
        MockMakerHooks hooks2 = new MockMakerHooks();

        HookTargets memory targets;
        HookData memory makerData;
        HookData memory takerHookData;

        if (testPostIn) {
            targets = HookTargets(address(hooks1), address(hooks2), address(0), address(0));
            makerData = HookData(abi.encodePacked("PRE_IN_DATA"), abi.encodePacked("POST_IN_DATA"), "", "");
            takerHookData = HookData(abi.encodePacked("TAKER_PRE_IN"), abi.encodePacked("TAKER_POST_IN"), "", "");
        } else {
            targets = HookTargets(address(hooks1), address(0), address(hooks2), address(0));
            makerData = HookData(abi.encodePacked("PRE_IN_DATA"), "", abi.encodePacked("PRE_OUT_DATA"), "");
            takerHookData = HookData(abi.encodePacked("TAKER_PRE_IN"), "", abi.encodePacked("TAKER_PRE_OUT"), "");
        }

        ISwapVM.Order memory order = _buildOrder(targets, makerData, testPostIn ? 0xF002 : 0xCCCC);
        bytes32 orderHash = swapVM.hash(order);

        TakerConfig memory cfg = _defaultTakerConfig();
        cfg.hookData = takerHookData;

        _executeSwap(order, 50e18, _buildTakerData(cfg, _signOrder(order)));

        // Verify hooks1 (preTransferIn)
        assertEq(hooks1.preTransferInCallCount(), 1);
        if (testPostIn) {
            assertEq(hooks1.postTransferInCallCount(), 0);
        } else {
            assertEq(hooks1.preTransferOutCallCount(), 0);
        }

        // Verify hooks2
        if (testPostIn) {
            assertEq(hooks2.postTransferInCallCount(), 1);
            assertEq(hooks2.preTransferInCallCount(), 0);

            (address lastMaker, address lastTaker, address lastTokenIn, address lastTokenOut,,,
                bytes32 lastOrderHash, bytes memory lastMakerData, bytes memory lastTakerData) = hooks2.lastPostTransferIn();

            assertEq(lastMaker, maker);
            assertEq(lastTaker, taker);
            assertEq(lastTokenIn, address(tokenB));
            assertEq(lastTokenOut, address(tokenA));
            assertEq(lastOrderHash, orderHash);
            assertEq(lastMakerData, makerData.postIn);
            assertEq(lastTakerData, takerHookData.postIn);
        } else {
            assertEq(hooks2.preTransferOutCallCount(), 1);
            assertEq(hooks2.preTransferInCallCount(), 0);

            (address lastMaker, address lastTaker, address lastTokenIn, address lastTokenOut,,,
                bytes32 lastOrderHash, bytes memory lastMakerData, bytes memory lastTakerData) = hooks2.lastPreTransferOut();

            assertEq(lastMaker, maker);
            assertEq(lastTaker, taker);
            assertEq(lastTokenIn, address(tokenB));
            assertEq(lastTokenOut, address(tokenA));
            assertEq(lastOrderHash, orderHash);
            assertEq(lastMakerData, makerData.preOut);
            assertEq(lastTakerData, takerHookData.preOut);
        }
    }

    function test_AsymmetricHookData_EmptyMakerNonEmptyTaker() public {
        _testAsymmetricHookData(false);
    }

    function test_AsymmetricHookData_PostTransferIn_EmptyMakerNonEmptyTaker() public {
        _testAsymmetricHookData(true);
    }

    function _testAsymmetricHookData(bool testPostIn) internal {
        HookTargets memory targets;
        if (testPostIn) {
            targets = HookTargets(address(0), address(hooksContract), address(0), address(0));
        } else {
            targets = HookTargets(address(0), address(0), address(hooksContract), address(0));
        }

        // Empty maker data
        ISwapVM.Order memory order = _buildOrder(targets, HookData("", "", "", ""), testPostIn ? 0xF003 : 0xDDDD);

        // Non-empty taker data
        bytes memory takerProvidedData = testPostIn
            ? abi.encodePacked("TAKER_PROVIDED_DATA_FOR_POST_IN")
            : abi.encodePacked("TAKER_PROVIDED_DATA_FOR_PRE_OUT");

        TakerConfig memory cfg = _defaultTakerConfig();
        if (testPostIn) {
            cfg.hookData.postIn = takerProvidedData;
        } else {
            cfg.hookData.preOut = takerProvidedData;
        }

        hooksContract.resetCounters();
        _executeSwap(order, 50e18, _buildTakerData(cfg, _signOrder(order)));

        bytes memory lastMakerData;
        bytes memory lastTakerData;

        if (testPostIn) {
            assertEq(hooksContract.postTransferInCallCount(), 1);
            (,,,,,,, lastMakerData, lastTakerData) = hooksContract.lastPostTransferIn();
        } else {
            assertEq(hooksContract.preTransferOutCallCount(), 1);
            (,,,,,,, lastMakerData, lastTakerData) = hooksContract.lastPreTransferOut();
        }

        assertEq(lastMakerData.length, 0);
        assertEq(lastTakerData, takerProvidedData);
    }

    function test_MultipleConsecutiveSwaps_SameHook() public {
        _testMultipleConsecutiveSwaps(false);
    }

    function test_MultipleConsecutiveSwaps_SamePostTransferInHook() public {
        _testMultipleConsecutiveSwaps(true);
    }

    function _testMultipleConsecutiveSwaps(bool testPostIn) internal {
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        uint64[3] memory salts = testPostIn
            ? [uint64(0xF004), uint64(0xF005), uint64(0xF006)]
            : [uint64(0xEEE1), uint64(0xEEE2), uint64(0xEEE3)];

        string[3] memory orderLabels = ["ORDER_1", "ORDER_2", "ORDER_3"];
        string[3] memory swapLabels = ["SWAP_1", "SWAP_2", "SWAP_3"];
        uint256[3] memory amounts = [uint256(10e18), uint256(20e18), uint256(15e18)];

        hooksContract.resetCounters();

        for (uint256 i = 0; i < 3; i++) {
            HookTargets memory targets;
            HookData memory makerData;
            TakerConfig memory cfg = _defaultTakerConfig();

            if (testPostIn) {
                targets = HookTargets(address(0), address(hooksContract), address(0), address(0));
                makerData = HookData("", abi.encodePacked(orderLabels[i]), "", "");
                cfg.hookData.postIn = abi.encodePacked(swapLabels[i]);
            } else {
                targets = HookTargets(address(0), address(0), address(hooksContract), address(0));
                makerData = HookData("", "", abi.encodePacked(orderLabels[i]), "");
                cfg.hookData.preOut = abi.encodePacked(swapLabels[i]);
            }

            ISwapVM.Order memory order = _buildOrder(targets, makerData, salts[i]);
            _executeSwap(order, amounts[i], _buildTakerData(cfg, _signOrder(order)));

            bytes memory lastMakerData;
            uint256 expectedCount = i + 1;

            if (testPostIn) {
                assertEq(hooksContract.postTransferInCallCount(), expectedCount);
                (,,,,,,, lastMakerData,) = hooksContract.lastPostTransferIn();
            } else {
                assertEq(hooksContract.preTransferOutCallCount(), expectedCount);
                (,,,,,,, lastMakerData,) = hooksContract.lastPreTransferOut();
            }

            assertEq(lastMakerData, abi.encodePacked(orderLabels[i]));
        }
    }
}
