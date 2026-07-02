// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM } from "../src/SwapVM.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { SwapRegisters } from "../src/libs/VM.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Debug } from "../src/instructions/Debug.sol";

import { dynamic } from "./utils/Dynamic.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { AquaSwapVMHelper } from "./helpers/AquaSwapVMHelper.sol";
import { WETHMock } from "./mocks/WETHMock.sol";

/// @dev Has no receive/fallback, so any plain ETH transfer to it fails
contract EthRejector {}

/// @dev Contract taker that forwards a swap with attached ETH but cannot receive refunds
contract RefundRejectingTaker {
    function doSwap(
        ISwapVM router,
        ISwapVM.Order calldata order,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external payable returns (uint256, uint256, bytes32) {
        return router.swap{ value: msg.value }(order, amount, takerTraitsAndData);
    }
}

contract NativePaymentTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouterDebug public swapVM;
    WETHMock public weth;
    TokenMock public token;

    Aqua public aqua;
    AquaSwapVMHelper public aquaHelper;
    AquaSwapVMRouter public aquaRouter;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ORDER_BALANCE = 1000e18;
    uint256 constant AQUA_WETH_BALANCE = 100e18;
    uint256 constant AQUA_TOKEN_BALANCE = 200e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        weth = new WETHMock();
        token = new TokenMock("Token J", "TKJ");
        swapVM = new SwapVMRouterDebug(address(0), address(weth), makeAddr("owner"), "SwapVM", "1.0.0");

        aqua = new Aqua();
        aquaHelper = new AquaSwapVMHelper(address(aqua));
        aquaRouter = new AquaSwapVMRouter(address(aqua), address(weth), makeAddr("owner"), "SwapVM", "1.0.0");

        token.mint(maker, 1_000_000e18);

        vm.startPrank(maker);
        token.approve(address(swapVM), type(uint256).max);
        weth.approve(address(swapVM), type(uint256).max);
        token.approve(address(aqua), type(uint256).max);
        weth.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        token.approve(address(swapVM), type(uint256).max);
        weth.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== BUILDERS ====================

    function _buildOrder(
        bool makerUnwrapWeth,
        address receiver,
        bool allowZeroAmountIn,
        bytes memory programBytes
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        (address lowerToken, address higherToken) = address(weth) < address(token)
            ? (address(weth), address(token))
            : (address(token), address(weth));

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: lowerToken,
            tokenB: higherToken,
            shouldUnwrapWeth: makerUnwrapWeth,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: allowZeroAmountIn,
            receiver: receiver,
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

    function _buildXYCOrder(
        bool makerUnwrapWeth,
        address receiver
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                [uint256(ORDER_BALANCE), uint256(ORDER_BALANCE)]
            )),
            program.build(XYCSwap._xycSwapXD)
        );
        return _buildOrder(makerUnwrapWeth, receiver, false, programBytes);
    }

    function _buildTakerData(
        address takerAddr,
        bool isExactIn,
        bool isAToB,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: isExactIn,
            isAToB: isAToB,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: takerAddr,
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
    }

    function _buildAquaTakerData(
        address takerAddr,
        bool isAToB,
        bool useTransferFromAndAquaPush
    ) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: true,
            isAToB: isAToB,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: useTransferFromAndAquaPush,
            threshold: "",
            to: takerAddr,
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
        }));
    }

    function _prepareWeth(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        weth.deposit{ value: amount }();
    }

    function _wethIsAToB() internal view returns (bool) {
        return address(weth) < address(token);
    }

    /// @dev Ships an Aqua XYC strategy (weth/token) funded by the maker
    function _shipAquaOrder() internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        (address lowerToken, address higherToken) = address(weth) < address(token)
            ? (address(weth), address(token))
            : (address(token), address(weth));

        order = aquaHelper.createOrder(maker, TokenMock(lowerToken), TokenMock(higherToken));
        orderHash = aquaRouter.hash(order);

        _prepareWeth(maker, AQUA_WETH_BALANCE);
        token.mint(maker, AQUA_TOKEN_BALANCE);

        uint256 lowerBalance = lowerToken == address(weth) ? AQUA_WETH_BALANCE : AQUA_TOKEN_BALANCE;
        uint256 higherBalance = higherToken == address(weth) ? AQUA_WETH_BALANCE : AQUA_TOKEN_BALANCE;

        vm.prank(maker);
        aqua.ship(
            address(aquaRouter),
            abi.encode(order),
            dynamic([lowerToken, higherToken]),
            dynamic([lowerBalance, higherBalance])
        );
    }

    // ==================== SUCCESS: SIGNED ORDERS ====================

    function test_NativePayment_MakerReceivesWeth() public {
        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap{ value: amountIn }(order, amountIn, takerData);

        assertEq(actualAmountIn, amountIn, "amountIn mismatch");
        assertEq(taker.balance, 0, "Taker should have spent all attached ETH");
        assertEq(weth.balanceOf(maker), amountIn, "Maker should receive WETH minted from native payment");
        assertEq(token.balanceOf(taker), actualAmountOut, "Taker should receive tokenOut");
        assertEq(address(swapVM).balance, 0, "No ETH should remain in the router");
        assertEq(weth.balanceOf(address(swapVM)), 0, "No WETH should remain in the router");
    }

    function test_NativePayment_DoesNotTouchTakerWeth() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn); // taker also holds WETH with approval already set
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        swapVM.swap{ value: amountIn }(order, amountIn, takerData);

        assertEq(weth.balanceOf(taker), amountIn, "Native payment must take precedence over taker's WETH");
        assertEq(taker.balance, 0, "Attached ETH should be consumed");
    }

    function test_NativePayment_MakerUnwrap_ReceivesEth() public {
        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(true, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap{ value: amountIn }(order, amountIn, takerData);

        assertEq(maker.balance - makerEthBefore, actualAmountIn, "Maker should receive ETH directly");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");
        assertEq(weth.totalSupply(), 0, "ETH passthrough should not touch WETH at all");
        assertEq(address(swapVM).balance, 0, "No ETH should remain in the router");
    }

    function test_NativePayment_CustomReceiver_ReceivesWeth() public {
        address makerReceiver = makeAddr("makerReceiver");
        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, makerReceiver);
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap{ value: amountIn }(order, amountIn, takerData);

        assertEq(weth.balanceOf(makerReceiver), actualAmountIn, "Custom receiver should receive WETH");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");
    }

    function test_NativePayment_MakerUnwrap_CustomReceiver_ReceivesEth() public {
        address makerReceiver = makeAddr("makerReceiver");
        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(true, makerReceiver);
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap{ value: amountIn }(order, amountIn, takerData);

        assertEq(makerReceiver.balance, actualAmountIn, "Custom receiver should receive ETH");
        assertEq(maker.balance, 0, "Maker should not receive ETH");
    }

    function test_NativePayment_ExcessRefunded() public {
        uint256 amountIn = 10e18;
        uint256 excess = 5e18;
        vm.deal(taker, amountIn + excess);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap{ value: amountIn + excess }(order, amountIn, takerData);

        assertEq(actualAmountIn, amountIn, "amountIn mismatch");
        assertEq(taker.balance, excess, "Excess ETH should be refunded to the taker");
        assertEq(weth.balanceOf(maker), amountIn, "Maker should receive exactly amountIn in WETH");
        assertEq(address(swapVM).balance, 0, "No ETH should remain in the router");
    }

    function test_NativePayment_ExactOut_RefundsExcess() public {
        uint256 amountOut = 5e18;

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, false, _wethIsAToB(), signature);

        (uint256 quotedIn,,) = swapVM.quote(order, amountOut, takerData);
        uint256 excess = 1e18;
        vm.deal(taker, quotedIn + excess);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap{ value: quotedIn + excess }(order, amountOut, takerData);

        assertEq(actualAmountOut, amountOut, "amountOut mismatch");
        assertEq(actualAmountIn, quotedIn, "amountIn should match quote");
        assertEq(taker.balance, excess, "Only computed amountIn should be consumed");
        assertEq(weth.balanceOf(maker), actualAmountIn, "Maker should receive computed amountIn in WETH");
    }

    function test_NativePayment_ZeroAmountIn_FullRefund() public {
        uint256 amountOut = 5e18;
        uint256 attached = 1e18;

        // Program forces amountIn = 0 with a positive amountOut to reach the full-refund branch
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = program.build(Debug._patchSwapRegisters, abi.encode(SwapRegisters({
            balanceIn: 0,
            balanceOut: 0,
            amountIn: 0,
            amountOut: amountOut,
            amountNetPulled: 0
        })));

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), true, programBytes);
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.deal(taker, attached);
        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap{ value: attached }(order, 0, takerData);

        assertEq(actualAmountIn, 0, "amountIn should be zero");
        assertEq(actualAmountOut, amountOut, "amountOut mismatch");
        assertEq(taker.balance, attached, "Full msg.value should be refunded when amountIn is zero");
        assertEq(token.balanceOf(taker), amountOut, "Taker should still receive tokenOut");
        assertEq(address(swapVM).balance, 0, "No ETH should remain in the router");
    }

    function testFuzz_NativePayment(uint128 rawAmount, uint96 rawExcess, bool makerUnwrapWeth) public {
        uint256 amountIn = bound(uint256(rawAmount), 1e15, ORDER_BALANCE / 2);
        uint256 excess = bound(uint256(rawExcess), 0, 100 ether);
        vm.deal(taker, amountIn + excess);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(makerUnwrapWeth, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap{ value: amountIn + excess }(order, amountIn, takerData);

        assertEq(actualAmountIn, amountIn, "amountIn mismatch");
        assertEq(taker.balance, excess, "Excess should be refunded");
        assertEq(token.balanceOf(taker), actualAmountOut, "Taker should receive tokenOut");
        if (makerUnwrapWeth) {
            assertEq(maker.balance, amountIn, "Maker should receive ETH");
        } else {
            assertEq(weth.balanceOf(maker), amountIn, "Maker should receive WETH");
        }
        assertEq(address(swapVM).balance, 0, "No ETH should remain in the router");
        assertEq(weth.balanceOf(address(swapVM)), 0, "No WETH should remain in the router");
    }

    // ==================== SUCCESS: AQUA ORDERS ====================

    function test_NativePayment_AquaPush() public {
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipAquaOrder();

        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);
        // Note: the taker holds no WETH and grants no approvals to aquaRouter — pure native payment

        (uint256 wethBalanceBefore,) = aqua.rawBalances(maker, address(aquaRouter), orderHash, address(weth));
        bytes memory takerData = _buildAquaTakerData(taker, _wethIsAToB(), true);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = aquaRouter.swap{ value: amountIn }(order, amountIn, takerData);

        (uint256 wethBalanceAfter,) = aqua.rawBalances(maker, address(aquaRouter), orderHash, address(weth));

        assertEq(actualAmountIn, amountIn, "amountIn mismatch");
        assertEq(wethBalanceAfter - wethBalanceBefore, amountIn, "Aqua WETH balance should grow by amountIn");
        assertEq(taker.balance, 0, "Taker should have spent all attached ETH");
        assertEq(token.balanceOf(taker), actualAmountOut, "Taker should receive tokenOut");
        assertEq(address(aquaRouter).balance, 0, "No ETH should remain in the router");
        assertEq(weth.balanceOf(address(aquaRouter)), 0, "No WETH should remain in the router");
    }

    function test_NativePayment_AquaPush_ExcessRefunded() public {
        (ISwapVM.Order memory order,) = _shipAquaOrder();

        uint256 amountIn = 10e18;
        uint256 excess = 3e18;
        vm.deal(taker, amountIn + excess);

        bytes memory takerData = _buildAquaTakerData(taker, _wethIsAToB(), true);

        vm.prank(taker);
        aquaRouter.swap{ value: amountIn + excess }(order, amountIn, takerData);

        assertEq(taker.balance, excess, "Excess ETH should be refunded to the taker");
        assertEq(address(aquaRouter).balance, 0, "No ETH should remain in the router");
    }

    // ==================== REVERT CASES ====================

    function test_RevertWhen_MsgValueWithNonWethTokenIn() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE); // maker provides WETH as tokenOut
        token.mint(taker, amountIn);
        vm.deal(taker, 1e18);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        // tokenIn = token, tokenOut = weth
        bytes memory takerData = _buildTakerData(taker, true, !_wethIsAToB(), signature);

        vm.expectRevert(SwapVM.MsgValueInvalidToken.selector);
        vm.prank(taker);
        swapVM.swap{ value: 1e18 }(order, amountIn, takerData);
    }

    function test_RevertWhen_NotEnoughMsgValue() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn); // even with WETH available there must be no fallback to transferFrom
        vm.deal(taker, amountIn - 1);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.expectRevert(SwapVM.NotEnoughMsgValueAttached.selector);
        vm.prank(taker);
        swapVM.swap{ value: amountIn - 1 }(order, amountIn, takerData);
    }

    function test_RevertWhen_ExactOutNotEnoughMsgValue() public {
        uint256 amountOut = 5e18;

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, false, _wethIsAToB(), signature);

        (uint256 quotedIn,,) = swapVM.quote(order, amountOut, takerData);
        vm.deal(taker, quotedIn - 1);

        vm.expectRevert(SwapVM.NotEnoughMsgValueAttached.selector);
        vm.prank(taker);
        swapVM.swap{ value: quotedIn - 1 }(order, amountOut, takerData);
    }

    function test_RevertWhen_AquaOrderWithoutPushReceivesMsgValue() public {
        (ISwapVM.Order memory order,) = _shipAquaOrder();

        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        bytes memory takerData = _buildAquaTakerData(taker, _wethIsAToB(), false);

        vm.expectRevert(SwapVM.UnexpectedMsgValue.selector);
        vm.prank(taker);
        aquaRouter.swap{ value: amountIn }(order, amountIn, takerData);
    }

    function test_RevertWhen_MakerEthReceiverRejectsEth() public {
        address rejector = address(new EthRejector());
        uint256 amountIn = 10e18;
        vm.deal(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(true, rejector);
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.expectRevert(SwapVM.EthTransferFailed.selector);
        vm.prank(taker);
        swapVM.swap{ value: amountIn }(order, amountIn, takerData);
    }

    function test_RevertWhen_RefundReceiverRejectsEth() public {
        RefundRejectingTaker mockTaker = new RefundRejectingTaker();
        uint256 amountIn = 10e18;
        uint256 excess = 5e18;
        vm.deal(address(this), amountIn + excess);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(address(mockTaker), true, _wethIsAToB(), signature);

        vm.expectRevert(SwapVM.EthTransferFailed.selector);
        mockTaker.doSwap{ value: amountIn + excess }(ISwapVM(address(swapVM)), order, amountIn, takerData);
    }

    // ==================== REGRESSION: NO MSG.VALUE ====================

    function test_NoMsgValue_FallsBackToWethTransferFrom() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildXYCOrder(false, address(0));
        bytes memory takerData = _buildTakerData(taker, true, _wethIsAToB(), signature);

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, amountIn, takerData);

        assertEq(weth.balanceOf(taker), 0, "Taker WETH should be pulled via transferFrom");
        assertEq(weth.balanceOf(maker), actualAmountIn, "Maker should receive WETH");
        assertEq(taker.balance, 0, "No ETH involved");
    }
}
