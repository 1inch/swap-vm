// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { FeeFlatIn, FeeFlatOut } from "../src/instructions/FeeFlat.sol";
import { FeeBuilders } from "./utils/FeeBuilders.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { InvalidProtocolFeeProviderMock } from "./mocks/InvalidProtocolFeeProviderMock.sol";


uint256 constant ONE = 1e18;
uint256 constant BPS = 1e7;

contract DynamicProtocolFeeTest is Test, OpcodesDebug {
    SwapVMRouterDebug public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");
    address public protocolFeeRecipient;

    ProtocolFeeProviderMock public feeProvider;
    InvalidProtocolFeeProviderMock public invalidFeeProvider;

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouterDebug(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token I", "TKI"));
        tokenB = address(new TokenMock("Token J", "TKJ"));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 1000e18);
        TokenMock(tokenB).mint(maker, 1000e18);
        TokenMock(tokenA).mint(taker, 1000e18);
        TokenMock(tokenB).mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        protocolFeeRecipient = vm.addr(0x8888);

        // Deploy fee provider mock with default values
        feeProvider = new ProtocolFeeProviderMock(0.10e7, 0, protocolFeeRecipient, address(this));
        // Deploy invalid fee provider mock
        invalidFeeProvider = new InvalidProtocolFeeProviderMock();
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        address dynamicFeeProvider;
        uint24 flatInFeeBps;
        uint24 flatOutFeeBps;
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            // 0. Apply dynamic protocol fee
            setup.dynamicFeeProvider != address(0) ? FeeBuilders.protocolProviderIn(setup.dynamicFeeProvider) : bytes(""),
            // 1. Set initial token balances
            DynamicBalances.build(setup.balanceA, setup.balanceB),
            // 2. Apply flat feeIn (optional)
            setup.flatInFeeBps > 0 ? FeeFlatIn.build(setup.flatInFeeBps) : bytes(""),
            // 3. Apply flat feeOut (optional)
            setup.flatOutFeeBps > 0 ? FeeFlatOut.build(setup.flatOutFeeBps) : bytes(""),
            // 4. Perform the swap
            XYCSwap.build()
        );

        // === Create Order ===
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
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

    struct TakerSetup {
        bool isExactIn;
    }

    function _quotingTakerData(TakerSetup memory takerSetup) internal view returns (bytes memory takerData) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: takerSetup.isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
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
            signature: ""
        }));
    }

    function _swappingTakerData(bytes memory takerData, bytes memory signature) internal view returns (bytes memory) {
        bool isExactIn = (uint8(takerData[21]) & 0x01) != 0; // flags are bytes 20-21 of the traits header

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
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
    }

    // ========== Dynamic Protocol Fee Tests ==========

    function test_DynamicProtocolFee_ExactIn_ReceivedByRecipient() public {
        // Setup fee provider with 10% fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0.10e7, 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 amountOut,) = swapVM.swap(order, amountIn, exactInTakerDataSwap);

        // Protocol fee is collected from tokenIn (tokenA)
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Fee is exact: amountIn * feeBps / BPS, paid by taker at settlement
        assertEq(actualProtocolFee, amountIn * 0.10e7 / BPS, "Protocol fee should be collected from tokenIn");

        // ExactIn: taker always pays exactly the specified amountIn (fee carved out of maker receipt)
        assertEq(actualAmountIn, amountIn, "actualAmountIn should equal requested amountIn");

        // Verify amountOut is less than without fee
        uint256 noFeeAmountOut = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertLt(amountOut, noFeeAmountOut, "AmountOut should be less with protocol fee on amountIn");
    }

    function test_DynamicProtocolFee_ExactOut_ReceivedByRecipient() public {
        // Setup fee provider with 10% fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0.10e7, 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactOutTakerData = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory exactOutTakerDataSwap = _swappingTakerData(exactOutTakerData, signature);

        uint256 amountOut = 50e18;
        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap(order, amountOut, exactOutTakerDataSwap);

        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Calculate expected values
        uint256 baseAmountIn = setup.balanceA * amountOut / (setup.balanceB - amountOut);
        uint256 expectedProtocolFee = baseAmountIn * 0.10e7 / (BPS - 0.10e7);
        uint256 expectedTotalAmountIn = baseAmountIn + expectedProtocolFee;

        assertApproxEqAbs(actualProtocolFee, expectedProtocolFee, 1, "Protocol fee recipient should receive correct fee from tokenIn");
        assertApproxEqAbs(actualAmountIn, expectedTotalAmountIn, 1, "Taker should pay amountIn plus protocol fee");
        assertEq(actualAmountOut, amountOut, "AmountOut should match requested amount");
    }

    function test_DynamicProtocolFee_ZeroFee_NoTransfer() public {
        // Setup fee provider with 0% fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0, 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        swapVM.swap(order, amountIn, exactInTakerDataSwap);

        // No fee should be transferred
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertEq(actualProtocolFee, 0, "No fee should be transferred when feeBps is 0");
    }

    function test_DynamicProtocolFee_ZeroAddress_Reverts() public {
        // Setup fee provider with fee but zero recipient
        feeProvider.setRecipientAndFees(address(0), 0.10e7, 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        // No dedicated zero-recipient check anymore: the fee transfer to address(0) reverts inside ERC20
        vm.expectRevert();
        swapVM.swap(order, amountIn, exactInTakerDataSwap);
    }

    function test_DynamicProtocolFee_ProviderReturnsHighFee_Reverts() public {
        // Setup fee provider with excessive fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 1.5e7, 0); // 150%

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(FeeProtocol.FeeBpsOutOfRange.selector, 1.5e7, 0));
        swapVM.swap(order, amountIn, exactInTakerDataSwap);
    }

    function test_DynamicProtocolFee_ProviderReturnsFailedCall_Reverts() public {
        // Use invalid address as provider
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(invalidFeeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        vm.expectRevert(InvalidProtocolFeeProviderMock.FeeDynamicProtocolInvalidRecipient.selector);
        swapVM.swap(order, amountIn, exactInTakerDataSwap);
    }

    function test_DynamicProtocolFee_ZeroProvider_NoFee() public {
        // Use zero address as provider
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(0),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, exactInTakerDataSwap);

        // No fee should be transferred to protocol fee recipient
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertEq(actualProtocolFee, 0, "No fee should be transferred when provider is zero address");

        // Verify amountOut is greater than 0 (swap happened)
        assertGt(amountOut, 0, "AmountOut should be greater than 0");
    }

    function test_DynamicProtocolFee_WithFlatFee() public {
        // Setup fee provider with 10% fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0.10e7, 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0.05e7,  // 5% flat fee
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, exactInTakerDataSwap);

        // Both fees applied - verify protocol fee was collected
        uint256 protocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertGt(protocolFee, 0, "Protocol fee should be collected");

        // Verify amountOut is less than with no fees
        uint256 noFeeAmountOut = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertLt(amountOut, noFeeAmountOut, "AmountOut should be less with both fees applied");
    }

    function test_DynamicProtocolFee_ProviderCanChangeFee() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;

        // First swap with 10% fee
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0.10e7, 0);
        vm.prank(taker);
        swapVM.swap(order, amountIn, exactInTakerDataSwap);

        uint256 fee1 = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertGt(fee1, 0, "Fee should be collected with 10% rate");

        // Reset recipient balance
        vm.prank(protocolFeeRecipient);
        TokenMock(tokenA).transfer(address(1), fee1);

        // Change fee to 5%
        feeProvider.setRecipientAndFees(protocolFeeRecipient, 0.05e7, 0);
        vm.prank(taker);
        swapVM.swap(order, amountIn, exactInTakerDataSwap);

        uint256 fee2 = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertGt(fee2, 0, "Fee should be collected with 5% rate");

        // Lower fee bps should result in lower fee amount
        assertLt(fee2, fee1, "Lower fee bps should result in lower fee amount");
    }
}
