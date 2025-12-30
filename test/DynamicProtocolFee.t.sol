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
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { FeeExperimental, FeeArgsBuilderExperimental } from "../src/instructions/FeeExperimental.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { InvalidProtocolFeeProviderMock } from "./mocks/InvalidProtocolFeeProviderMock.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

uint256 constant ONE = 1e18;
uint256 constant BPS = 1e9;

contract DynamicProtocolFeeTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

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
        swapVM = new SwapVMRouterDebug(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

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
        feeProvider = new ProtocolFeeProviderMock(0.10e9, protocolFeeRecipient, address(this));
        // Deploy invalid fee provider mock
        invalidFeeProvider = new InvalidProtocolFeeProviderMock();
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        address dynamicFeeProvider;
        uint32 flatInFeeBps;
        uint32 flatOutFeeBps;
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory programBytes = bytes.concat(
            // 0. Apply dynamic protocol fee
            program.build(Fee._dynamicProtocolFeeAmountInXD,
                FeeArgsBuilder.buildDynamicProtocolFee(setup.dynamicFeeProvider)),
            // 1. Set initial token balances
            program.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
            // 2. Apply flat feeIn (optional)
            setup.flatInFeeBps > 0 ? program.build(Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(setup.flatInFeeBps)) : bytes(""),
            // 3. Apply flat feeOut (optional)
            setup.flatOutFeeBps > 0 ? program.build(FeeExperimental._flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(setup.flatOutFeeBps)) : bytes(""),
            // 4. Perform the swap
            program.build(XYCSwap._xycSwapXD)
        );

        // === Create Order ===
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
        bool isExactIn = (uint16(bytes2(takerData)) & 0x0001) != 0;

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
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
    }

    // ========== Dynamic Protocol Fee Tests ==========

    function test_DynamicProtocolFee_ExactIn_ReceivedByRecipient() public {
        // Setup fee provider with 10% fee
        feeProvider.setFeeBpsAndRecipient(0.10e9, protocolFeeRecipient);

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
        (uint256 actualAmountIn, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // Protocol fee is collected from tokenIn (tokenA)
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Verify fee was collected (non-zero)
        assertGt(actualProtocolFee, 0, "Protocol fee should be collected from tokenIn");

        // actualAmountIn returned is the effective amount used in swap after fee
        assertLt(actualAmountIn, amountIn, "actualAmountIn should be less than requested (after fee)");

        // Verify amountOut is less than without fee
        uint256 noFeeAmountOut = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertLt(amountOut, noFeeAmountOut, "AmountOut should be less with protocol fee on amountIn");
    }

    function test_DynamicProtocolFee_ExactOut_ReceivedByRecipient() public {
        // Setup fee provider with 10% fee
        feeProvider.setFeeBpsAndRecipient(0.10e9, protocolFeeRecipient);

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
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactOutTakerDataSwap);

        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Calculate expected values
        uint256 baseAmountIn = setup.balanceA * amountOut / (setup.balanceB - amountOut);
        uint256 expectedProtocolFee = baseAmountIn * 0.10e9 / (BPS - 0.10e9);
        uint256 expectedTotalAmountIn = baseAmountIn + expectedProtocolFee;

        assertApproxEqAbs(actualProtocolFee, expectedProtocolFee, 1, "Protocol fee recipient should receive correct fee from tokenIn");
        assertApproxEqAbs(actualAmountIn, expectedTotalAmountIn, 1, "Taker should pay amountIn plus protocol fee");
        assertEq(actualAmountOut, amountOut, "AmountOut should match requested amount");
    }

    function test_DynamicProtocolFee_ZeroFee_NoTransfer() public {
        // Setup fee provider with 0% fee
        feeProvider.setFeeBpsAndRecipient(0, protocolFeeRecipient);

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
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // No fee should be transferred
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertEq(actualProtocolFee, 0, "No fee should be transferred when feeBps is 0");
    }

    function test_DynamicProtocolFee_ZeroAddress_Reverts() public {
        // Setup fee provider with fee but zero recipient
        feeProvider.setFeeBpsAndRecipient(0.10e9, address(0));

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
        vm.expectRevert(Fee.FeeDynamicProtocolInvalidRecipient.selector);
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);
    }

    function test_DynamicProtocolFee_ProviderReturnsHighFee_Reverts() public {
        // Setup fee provider with excessive fee
        feeProvider.setFeeBpsAndRecipient(1.5e9, protocolFeeRecipient); // 150%

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
        vm.expectRevert(abi.encodeWithSelector(Fee.FeeBpsOutOfRange.selector, 1.5e9));
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);
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
        vm.expectRevert(Fee.FeeProtocolProviderFailedCall.selector);
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);
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
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // No fee should be transferred to protocol fee recipient
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertEq(actualProtocolFee, 0, "No fee should be transferred when provider is zero address");

        // Verify amountOut is greater than 0 (swap happened)
        assertGt(amountOut, 0, "AmountOut should be greater than 0");
    }

    function test_DynamicProtocolFee_WithFlatFee() public {
        // Setup fee provider with 10% fee
        feeProvider.setFeeBpsAndRecipient(0.10e9, protocolFeeRecipient);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            dynamicFeeProvider: address(feeProvider),
            flatInFeeBps: 0.05e9,  // 5% flat fee
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

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
        feeProvider.setFeeBpsAndRecipient(0.10e9, protocolFeeRecipient);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        uint256 fee1 = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertGt(fee1, 0, "Fee should be collected with 10% rate");

        // Reset recipient balance
        vm.prank(protocolFeeRecipient);
        TokenMock(tokenA).transfer(address(1), fee1);

        // Change fee to 5%
        feeProvider.setFeeBpsAndRecipient(0.05e9, protocolFeeRecipient);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        uint256 fee2 = TokenMock(tokenA).balanceOf(protocolFeeRecipient);
        assertGt(fee2, 0, "Fee should be collected with 5% rate");

        // Lower fee bps should result in lower fee amount
        assertLt(fee2, fee1, "Lower fee bps should result in lower fee amount");
    }
}
