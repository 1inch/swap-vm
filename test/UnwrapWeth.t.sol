// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { EthReceiver } from "@1inch/solidity-utils/contracts/mixins/EthReceiver.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { WETHMock } from "./mocks/WETHMock.sol";

contract UnwrapWethTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    WETHMock public weth;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ORDER_BALANCE = 1000e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        weth = new WETHMock();
        swapVM = new SwapVMRouter(address(0), address(weth), "SwapVM", "1.0.0");
        tokenB = new TokenMock("Token B", "TKB");

        tokenB.mint(maker, 1_000_000e18);
        tokenB.mint(taker, 1_000_000e18);

        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        weth.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        weth.approve(address(swapVM), type(uint256).max);
    }

    function _buildOrder(
        bool makerUnwrapWeth,
        address receiver,
        address tokenA,
        address tokenC
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenA, tokenC]),
                dynamic([uint256(ORDER_BALANCE), uint256(ORDER_BALANCE)])
            )),
            program.build(XYCSwap._xycSwapXD)
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: makerUnwrapWeth,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    function _buildTakerData(
        bool isExactIn,
        bool takerUnwrapWeth,
        address recipient,
        bytes memory signature
    ) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: takerUnwrapWeth,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: recipient,
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

    function _prepareWeth(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        weth.deposit{value: amount}();
    }

    function test_RejectDirectEtherTransfer() public {
        vm.deal(address(this), 1 ether);

        (bool success, bytes memory returnData) = address(swapVM).call{value: 1 ether}("");

        assertFalse(success, "Direct ether transfer should fail");
        assertEq(returnData, abi.encodeWithSelector(EthReceiver.EthDepositRejected.selector), "Should revert with EthDepositRejected");
    }
    // ==================== MAKER UNWRAP TESTS ====================

    function test_MakerShouldUnwrapWeth_SendsEthToMaker() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, address(0), address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 makerEthBefore = maker.balance;
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 amountOut,) = swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        // Maker receives ETH (not WETH) and sends tokenB
        assertEq(maker.balance - makerEthBefore, actualAmountIn, "Maker should receive ETH");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");
        assertEq(makerTokenBBefore - tokenB.balanceOf(maker), amountOut, "Maker should send tokenB");

        // Taker sends WETH and receives tokenB
        assertEq(takerWethBefore - weth.balanceOf(taker), actualAmountIn, "Taker should spend WETH");
        assertEq(tokenB.balanceOf(taker) - takerTokenBBefore, amountOut, "Taker should receive tokenB");
    }

    function test_MakerReceiverCanBeChanged_WithUnwrapWeth() public {
        address makerReceiver = makeAddr("makerReceiver");
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, makerReceiver, address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 receiverEthBefore = makerReceiver.balance;
        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        assertEq(makerReceiver.balance - receiverEthBefore, actualAmountIn, "Receiver should receive ETH");
        assertEq(maker.balance - makerEthBefore, 0, "Maker should not receive ETH");
        assertEq(weth.balanceOf(makerReceiver), 0, "Receiver should not receive WETH");
    }

    /// @notice Edge case: receiver is explicitly set to maker address (same as default)
    function test_MakerReceiverIsMaker_WithUnwrapWeth() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        // Explicitly set receiver to maker (should behave same as address(0))
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, maker, address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        assertEq(maker.balance - makerEthBefore, actualAmountIn, "Maker should receive ETH");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");
    }

    /// @notice Edge case: receiver is maker, no unwrap - should receive WETH
    function test_MakerReceiverIsMaker_NoUnwrap() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        // Explicitly set receiver to maker, no unwrap
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, maker, address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        assertEq(weth.balanceOf(maker) - makerWethBefore, actualAmountIn, "Maker should receive WETH");
        assertEq(maker.balance, makerEthBefore, "Maker ETH should not change");
    }

    // ==================== TAKER UNWRAP TESTS ====================

    function test_TakerShouldUnwrapWeth_SendsEthToTaker() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(true, true, taker, signature);

        uint256 takerEthBefore = taker.balance;
        uint256 makerWethBefore = weth.balanceOf(maker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(weth), amountIn, takerData);

        // Taker receives ETH (not WETH)
        assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH");
        assertEq(weth.balanceOf(taker), 0, "Taker should not receive WETH");

        // Maker sends WETH
        assertEq(makerWethBefore - weth.balanceOf(maker), amountOut, "Maker should spend WETH");
    }

    function test_TakerRecipientCanBeChanged_WithUnwrapWeth() public {
        address takerRecipient = makeAddr("takerRecipient");
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(true, true, takerRecipient, signature);

        uint256 recipientEthBefore = takerRecipient.balance;
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(weth), amountIn, takerData);

        assertEq(takerRecipient.balance - recipientEthBefore, amountOut, "Recipient should receive ETH");
        assertEq(taker.balance - takerEthBefore, 0, "Taker should not receive ETH");
        assertEq(weth.balanceOf(takerRecipient), 0, "Recipient should not receive WETH");
    }

    /// @notice Edge case: recipient is explicitly set to taker address (same as default)
    function test_TakerRecipientIsTaker_WithUnwrapWeth() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        // Explicitly set recipient to taker (should behave same as address(0))
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(true, true, taker, signature);

        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(weth), amountIn, takerData);

        assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH");
        assertEq(weth.balanceOf(taker), 0, "Taker should not receive WETH");
    }

    /// @notice Edge case: recipient is taker, no unwrap - should receive WETH
    function test_TakerRecipientIsTaker_NoUnwrap() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        // Explicitly set recipient to taker, no unwrap
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 takerWethBefore = weth.balanceOf(taker);
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(weth), amountIn, takerData);

        assertEq(weth.balanceOf(taker) - takerWethBefore, amountOut, "Taker should receive WETH");
        assertEq(taker.balance, takerEthBefore, "Taker ETH should not change");
    }

    // ==================== NO UNWRAP TESTS ====================

    function test_NoUnwrap_WethTransferredAsToken() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);
        _prepareWeth(maker, ORDER_BALANCE);

        // Neither party unwraps - WETH transferred as ERC20
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);
        uint256 makerEthBefore = maker.balance;
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        // WETH transferred as token, no ETH changes
        assertEq(weth.balanceOf(maker) - makerWethBefore, actualAmountIn, "Maker should receive WETH");
        assertEq(takerWethBefore - weth.balanceOf(taker), actualAmountIn, "Taker should spend WETH");
        assertEq(maker.balance, makerEthBefore, "Maker ETH should not change");
        assertEq(taker.balance, takerEthBefore, "Taker ETH should not change");
    }

    // ==================== EXACTOUT MODE TESTS ====================

    function test_MakerUnwrapWeth_ExactOut() public {
        uint256 amountOut = 10e18; // Want this much tokenB
        _prepareWeth(taker, 100e18); // Plenty of WETH

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, address(0), address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(false, false, taker, signature); // ExactOut

        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(tokenB), amountOut, takerData);

        assertGt(actualAmountIn, 0, "Should have paid some WETH");
        assertEq(maker.balance - makerEthBefore, actualAmountIn, "Maker should receive ETH");
    }

    function test_TakerUnwrapWeth_ExactOut() public {
        uint256 amountOut = 10e18; // Want this much WETH (as ETH)
        _prepareWeth(maker, ORDER_BALANCE);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(false, true, taker, signature); // ExactOut

        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        swapVM.swap(order, address(tokenB), address(weth), amountOut, takerData);

        assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive exact ETH amount");
    }

    // ==================== FUZZ TESTS ====================

    function test_UnwrapWeth_Fuzz(
        bool makerUnwrapWeth,
        bool takerUnwrapWeth,
        bool isExactIn,
        uint128 rawAmount
    ) public {
        // Can't have same token for both in and out
        vm.assume(!(makerUnwrapWeth && takerUnwrapWeth));

        uint256 amount = bound(uint256(rawAmount), 1e15, ORDER_BALANCE / 2);

        // Setup tokens based on unwrap flags
        address tokenIn;
        address tokenOut;

        if (makerUnwrapWeth) {
            // Taker sends WETH, maker receives as ETH
            tokenIn = address(weth);
            tokenOut = address(tokenB);
            _prepareWeth(taker, amount * 2);
        } else if (takerUnwrapWeth) {
            // Maker sends WETH, taker receives as ETH
            tokenIn = address(tokenB);
            tokenOut = address(weth);
            _prepareWeth(maker, ORDER_BALANCE);
        } else {
            // No unwrap, use WETH as tokenIn for variety
            tokenIn = address(weth);
            tokenOut = address(tokenB);
            _prepareWeth(taker, amount * 2);
        }

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(makerUnwrapWeth, address(0), tokenIn, tokenOut);
        bytes memory takerData = _buildTakerData(isExactIn, takerUnwrapWeth, taker, signature);

        uint256 makerEthBefore = maker.balance;
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, tokenIn, tokenOut, amount, takerData);

        if (makerUnwrapWeth) {
            assertEq(maker.balance - makerEthBefore, amountIn, "Maker should receive ETH when unwrapping");
        } else {
            assertEq(maker.balance, makerEthBefore, "Maker ETH should not change");
        }

        if (takerUnwrapWeth) {
            assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH when unwrapping");
        } else {
            assertEq(taker.balance, takerEthBefore, "Taker ETH should not change");
        }
    }

    // ==================== QUOTE TESTS ====================

    function test_Quote_UnwrapFlagsDoNotAffectQuote() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        // Quote with unwrap
        (ISwapVM.Order memory order1, bytes memory sig1) = _buildOrder(true, address(0), address(weth), address(tokenB));
        bytes memory takerData1 = _buildTakerData(true, false, taker, sig1);

        // Quote without unwrap
        (ISwapVM.Order memory order2, bytes memory sig2) = _buildOrder(false, address(0), address(weth), address(tokenB));
        bytes memory takerData2 = _buildTakerData(true, false, taker, sig2);

        ISwapVM viewRouter = swapVM.asView();

        (, uint256 quoteOut1,) = viewRouter.quote(order1, address(weth), address(tokenB), amountIn, takerData1);
        (, uint256 quoteOut2,) = viewRouter.quote(order2, address(weth), address(tokenB), amountIn, takerData2);

        // Unwrap flag shouldn't affect the calculated amounts
        assertEq(quoteOut1, quoteOut2, "Quote should be same regardless of unwrap flag");
    }
}
