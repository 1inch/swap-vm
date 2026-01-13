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
    TokenMock public token;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ORDER_BALANCE = 1000e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        weth = new WETHMock();
        swapVM = new SwapVMRouter(address(0), address(weth), "SwapVM", "1.0.0");
        token = new TokenMock("Token B", "TKB");

        token.mint(maker, 1_000_000e18);
        token.mint(taker, 1_000_000e18);

        vm.prank(maker);
        token.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        weth.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        token.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        weth.approve(address(swapVM), type(uint256).max);
    }

    function _buildOrder(
        bool makerUnwrapWeth,
        address receiver,
        address tokenA,
        address tokenB
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenA, tokenB]),
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

    function test_MakerShouldReciveEth() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, address(0), address(weth), address(token));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 makerEthBefore = maker.balance;
        uint256 takerWethBefore = weth.balanceOf(taker);

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(token), amountIn, takerData);

        // Maker receives ETH (not WETH) and sends tokens
        assertEq(maker.balance - makerEthBefore, actualAmountIn, "Maker should receive ETH");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");

        // Taker sends WETH and receives tokens
        assertEq(takerWethBefore - weth.balanceOf(taker), actualAmountIn, "Taker should spend WETH");
    }

    function test_MakerShouldReciveEthToCustomAddress() public {
        address makerReceiver = makeAddr("makerReceiver");
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, makerReceiver, address(weth), address(token));
        bytes memory takerData = _buildTakerData(true, false, taker, signature);

        uint256 receiverEthBefore = makerReceiver.balance;
        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        (uint256 actualAmountIn,,) = swapVM.swap(order, address(weth), address(token), amountIn, takerData);

        assertEq(makerReceiver.balance - receiverEthBefore, actualAmountIn, "Receiver should receive ETH");
        assertEq(maker.balance, makerEthBefore, "Maker should not receive ETH");
        assertEq(weth.balanceOf(makerReceiver), 0, "Receiver should not receive WETH");
    }

    // ==================== TAKER UNWRAP TESTS ====================

    function test_TakerShouldReciveEth() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(token), address(weth));
        bytes memory takerData = _buildTakerData(true, true, taker, signature);

        uint256 takerEthBefore = taker.balance;
        uint256 makerWethBefore = weth.balanceOf(maker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(token), address(weth), amountIn, takerData);

        // Taker receives ETH (not WETH)
        assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH");
        assertEq(weth.balanceOf(taker), 0, "Taker should not receive WETH");

        // Maker sends WETH
        assertEq(makerWethBefore - weth.balanceOf(maker), amountOut, "Maker should spend WETH");
    }

    function test_TakerShouldReciveEthToCustomAddress() public {
        address takerRecipient = makeAddr("takerRecipient");
        uint256 amountIn = 10e18;
        _prepareWeth(maker, ORDER_BALANCE);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(0), address(token), address(weth));
        bytes memory takerData = _buildTakerData(true, true, takerRecipient, signature);

        uint256 recipientEthBefore = takerRecipient.balance;
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(token), address(weth), amountIn, takerData);

        assertEq(takerRecipient.balance - recipientEthBefore, amountOut, "Recipient should receive ETH");
        assertEq(taker.balance - takerEthBefore, 0, "Taker should not receive ETH");
        assertEq(weth.balanceOf(takerRecipient), 0, "Recipient should not receive WETH");
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
            tokenOut = address(token);
            _prepareWeth(taker, amount * 2);
        } else if (takerUnwrapWeth) {
            // Maker sends WETH, taker receives as ETH
            tokenIn = address(token);
            tokenOut = address(weth);
            _prepareWeth(maker, ORDER_BALANCE);
        } else {
            // No unwrap, use WETH as tokenIn for variety
            tokenIn = address(weth);
            tokenOut = address(token);
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
}
