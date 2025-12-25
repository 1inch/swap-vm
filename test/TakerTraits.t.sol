// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
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

/**
 * @title TakerTraitsTest
 * @notice Integration tests for TakerTraits functionality with LimitSwap
 * @dev Tests deadline, threshold, to, isExactIn, strictThreshold features
 */
contract TakerTraitsTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");
    address public recipient = makeAddr("recipient");

    uint256 constant MAKER_BALANCE_A = 100e18;
    uint256 constant MAKER_BALANCE_B = 200e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup initial balances
        tokenA.mint(maker, 10000e18);
        tokenB.mint(taker, 10000e18);

        // Approve SwapVM
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ==================== Deadline Tests ====================

    function test_Deadline_NotSet_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x1001);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        // deadline = 0 by default (no deadline)

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
    }

    function test_Deadline_Valid_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x1002);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.deadline = uint40(block.timestamp + 3600); // 1 hour in future

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
    }

    function test_Deadline_Expired_Reverts() public {
        vm.warp(1700000000);

        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x1003);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.deadline = uint40(block.timestamp - 1); // 1 second in past

        vm.prank(taker);
        vm.expectRevert(TakerTraitsLib.TakerTraitsDeadlineExpired.selector);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));
    }

    function test_Deadline_AtCurrentTimestamp_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x1004);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.deadline = uint40(block.timestamp); // Exactly now

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
    }

    // ==================== Threshold Tests ====================

    function test_ExactIn_MinThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2001);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.threshold = abi.encodePacked(uint256(20e18)); // min 20 out

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountOut, 25e18);
        assertTrue(amountOut >= 20e18, "Output should meet threshold");
    }

    function test_ExactIn_MinThreshold_Fails() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2002);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.threshold = abi.encodePacked(uint256(30e18)); // min 30, but only getting 25

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector, 25e18, 30e18));
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));
    }

    function test_ExactOut_MaxThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2003);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isExactIn = false;
        args.threshold = abi.encodePacked(uint256(60e18)); // max 60 in

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 25e18, TakerTraitsLib.build(args)
        );

        assertEq(amountOut, 25e18);
        assertEq(amountIn, 50e18);
        assertTrue(amountIn <= 60e18, "Input should be within max threshold");
    }

    function test_ExactOut_MaxThreshold_Fails() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2004);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isExactIn = false;
        args.threshold = abi.encodePacked(uint256(40e18)); // max 40, but needs 50

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsExceedingMaxInputAmount.selector, 50e18, 40e18));
        swapVM.swap(order, address(tokenB), address(tokenA), 25e18, TakerTraitsLib.build(args));
    }

    function test_StrictThreshold_ExactMatch_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2005);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isStrictThresholdAmount = true;
        args.threshold = abi.encodePacked(uint256(25e18)); // exact 25 out

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountOut, 25e18);
    }

    function test_StrictThreshold_Mismatch_Fails() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x2006);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isStrictThresholdAmount = true;
        args.threshold = abi.encodePacked(uint256(20e18)); // wants exact 20, getting 25

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsNonExactThresholdAmountOut.selector, 25e18, 20e18));
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));
    }

    // ==================== To (Recipient) Tests ====================

    function test_To_NotSet_SendsToTaker() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x3001);

        uint256 takerBalanceBefore = tokenA.balanceOf(taker);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        // to = address(0) by default

        vm.prank(taker);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));

        assertEq(tokenA.balanceOf(taker), takerBalanceBefore + 25e18, "Tokens should go to taker");
        assertEq(tokenA.balanceOf(recipient), 0, "Recipient should have 0");
    }

    function test_To_CustomRecipient() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x3002);

        uint256 takerBalanceBefore = tokenA.balanceOf(taker);
        uint256 recipientBalanceBefore = tokenA.balanceOf(recipient);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.to = recipient;

        vm.prank(taker);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));

        assertEq(tokenA.balanceOf(taker), takerBalanceBefore, "Taker balance should not change");
        assertEq(tokenA.balanceOf(recipient), recipientBalanceBefore + 25e18, "Tokens should go to recipient");
    }

    // ==================== Combined Tests ====================

    function test_CombinedFeatures_DeadlineAndThreshold() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x4001);

        uint256 recipientBalanceBefore = tokenA.balanceOf(recipient);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.threshold = abi.encodePacked(uint256(20e18)); // min 20 out
        args.to = recipient;
        args.deadline = uint40(block.timestamp + 3600); // 1 hour

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountOut, 25e18);
        assertEq(tokenA.balanceOf(recipient), recipientBalanceBefore + 25e18);
    }

    // ==================== isFirstTransferFromTaker Tests ====================

    function test_IsFirstTransferFromTaker_True() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x5001);

        uint256 takerTokenBBefore = tokenB.balanceOf(taker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        // isFirstTransferFromTaker = true by default

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
        assertEq(takerTokenBBefore - tokenB.balanceOf(taker), 50e18, "Taker should have spent 50 tokenB");
        assertEq(tokenB.balanceOf(maker) - makerTokenBBefore, 50e18, "Maker should have received 50 tokenB");
    }

    function test_IsFirstTransferFromTaker_False() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x5002);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isFirstTransferFromTaker = false; // Maker sends first

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
    }

    // ==================== Build Validation Tests ====================

    function test_Build_ValidThreshold_32Bytes() public pure {
        TakerTraitsLib.Args memory args;
        args.taker = address(0x1234);
        args.threshold = abi.encodePacked(uint256(100e18)); // 32 bytes

        bytes memory packed = TakerTraitsLib.build(args);
        assertTrue(packed.length > 0, "Should build successfully");
    }

    function test_Build_EmptyThreshold_Valid() public pure {
        TakerTraitsLib.Args memory args;
        args.taker = address(0x1234);
        args.threshold = ""; // empty

        bytes memory packed = TakerTraitsLib.build(args);
        assertTrue(packed.length > 0, "Should build successfully");
    }

    // ==================== Full Data Slices Test ====================

    function test_AllDataSlices_Populated() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x7001);

        bytes memory hookData = abi.encodePacked("hook_data_for_maker");

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.threshold = abi.encodePacked(uint256(20e18));
        args.to = recipient;
        args.deadline = uint40(block.timestamp + 3600);
        args.preTransferInHookData = hookData;
        args.postTransferInHookData = hookData;
        args.preTransferOutHookData = hookData;
        args.postTransferOutHookData = hookData;

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);
        assertEq(tokenA.balanceOf(recipient), 25e18, "Tokens should go to recipient");
    }

    // ==================== TakerAmount Mismatch Tests ====================

    function test_ExactIn_TakerAmountMismatch() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x8001);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);

        vm.prank(taker);
        (uint256 amountIn,,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
    }

    function test_ExactOut_TakerAmountMatch() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createLimitOrder(0x8002);

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.isExactIn = false;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 25e18, TakerTraitsLib.build(args)
        );

        assertEq(amountOut, 25e18);
    }

    // ==================== Taker Hook Data Tests ====================

    function test_TakerHookData_PassedToHooks() public {
        MockMakerHooks hooksContract = new MockMakerHooks();

        bytes memory takerPreInData = abi.encodePacked("TAKER_PRE_IN_DATA");
        bytes memory takerPostInData = abi.encodePacked("TAKER_POST_IN_DATA");
        bytes memory takerPreOutData = abi.encodePacked("TAKER_PRE_OUT_DATA");
        bytes memory takerPostOutData = abi.encodePacked("TAKER_POST_OUT_DATA");

        bytes memory makerPreInData = abi.encodePacked("MAKER_PRE_IN");
        bytes memory makerPostInData = abi.encodePacked("MAKER_POST_IN");
        bytes memory makerPreOutData = abi.encodePacked("MAKER_PRE_OUT");
        bytes memory makerPostOutData = abi.encodePacked("MAKER_POST_OUT");

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithHooks(
            0x9001, address(hooksContract),
            makerPreInData, makerPostInData, makerPreOutData, makerPostOutData
        );

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.preTransferInHookData = takerPreInData;
        args.postTransferInHookData = takerPostInData;
        args.preTransferOutHookData = takerPreOutData;
        args.postTransferOutHookData = takerPostOutData;

        vm.prank(taker);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args));

        assertTrue(hooksContract.allHooksCalled(), "All hooks should be called");

        (,,,,,,,, bytes memory lastTakerData) = hooksContract.lastPreTransferIn();
        assertEq(lastTakerData, takerPreInData, "PreTransferIn: incorrect taker data");

        (,,,,,,,, lastTakerData) = hooksContract.lastPostTransferIn();
        assertEq(lastTakerData, takerPostInData, "PostTransferIn: incorrect taker data");

        (,,,,,,,, lastTakerData) = hooksContract.lastPreTransferOut();
        assertEq(lastTakerData, takerPreOutData, "PreTransferOut: incorrect taker data");

        (,,,,,,,, lastTakerData) = hooksContract.lastPostTransferOut();
        assertEq(lastTakerData, takerPostOutData, "PostTransferOut: incorrect taker data");
    }

    function test_TakerHookData_EmptyWithMakerHooks() public {
        MockMakerHooks hooksContract = new MockMakerHooks();
        bytes memory makerPreInData = abi.encodePacked("MAKER_DATA");

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithHooks(
            0x9002, address(hooksContract), makerPreInData, makerPreInData, "", ""
        );

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        // Hook data is empty by default

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);

        assertEq(hooksContract.preTransferInCallCount(), 1, "preTransferIn should be called");
        assertEq(hooksContract.postTransferInCallCount(), 1, "postTransferIn should be called");

        (,,,,,,,, bytes memory lastTakerData) = hooksContract.lastPreTransferIn();
        assertEq(lastTakerData.length, 0, "PreTransferIn: taker data should be empty");
    }

    function test_TakerHookData_OnlyPreTransferIn() public {
        MockMakerHooks hooksContract = new MockMakerHooks();

        bytes memory takerPreInData = abi.encodePacked("ONLY_PRE_IN");
        bytes memory makerPreInData = abi.encodePacked("MAKER");

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithHooks(
            0x9003, address(hooksContract), makerPreInData, "", "", ""
        );

        TakerTraitsLib.Args memory args = _defaultTakerArgs(signature);
        args.preTransferInHookData = takerPreInData;

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 50e18, TakerTraitsLib.build(args)
        );

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 25e18);

        (,,,,,,,, bytes memory lastTakerData) = hooksContract.lastPreTransferIn();
        assertEq(lastTakerData, takerPreInData, "PreTransferIn: taker data should match");
    }

    // ==================== Helper Functions ====================

    function _defaultTakerArgs(bytes memory signature) internal view returns (TakerTraitsLib.Args memory args) {
        args = TakerTraitsLib.Args({
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
        });
    }

    function _createLimitOrder(uint64 salt) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([MAKER_BALANCE_A, MAKER_BALANCE_B])
                )),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(salt))
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

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _createOrderWithHooks(
        uint64 salt,
        address hooksTarget,
        bytes memory preInData,
        bytes memory postInData,
        bytes memory preOutData,
        bytes memory postOutData
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([MAKER_BALANCE_A, MAKER_BALANCE_B])
                )),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(salt))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: preInData.length > 0,
            hasPostTransferInHook: postInData.length > 0,
            hasPreTransferOutHook: preOutData.length > 0,
            hasPostTransferOutHook: postOutData.length > 0,
            preTransferInTarget: preInData.length > 0 ? hooksTarget : address(0),
            preTransferInData: preInData,
            postTransferInTarget: postInData.length > 0 ? hooksTarget : address(0),
            postTransferInData: postInData,
            preTransferOutTarget: preOutData.length > 0 ? hooksTarget : address(0),
            preTransferOutData: preOutData,
            postTransferOutTarget: postOutData.length > 0 ? hooksTarget : address(0),
            postTransferOutData: postOutData,
            program: programBytes
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }
}
