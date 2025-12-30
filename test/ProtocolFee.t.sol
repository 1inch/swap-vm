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
import { FeeExperimental } from "../src/instructions/FeeExperimental.sol";
import { Debug } from "../src/instructions/Debug.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

uint256 constant ONE = 1e18;
uint256 constant BPS = 1e9;

contract ProtocolFeeTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouterDebug public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");
    address public protocolFeeRecipient;

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
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint32 protocolFeeBps;
        uint32 flatInFeeBps;
        uint32 flatOutFeeBps;
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        return _createOrderWithFeeType(setup, false); // default: protocol fee on amountOut
    }

    function _createOrderWithFeeType(MakerSetup memory setup, bool protocolFeeOnAmountIn) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory programBytes = bytes.concat(
            // 0. Apply protocol fee (optional)
            setup.protocolFeeBps > 0 ? (
                protocolFeeOnAmountIn
                    ? program.build(Fee._protocolFeeAmountInXD,
                        FeeArgsBuilder.buildProtocolFee(setup.protocolFeeBps, protocolFeeRecipient))
                    : program.build(FeeExperimental._protocolFeeAmountOutXD,
                        FeeArgsBuilder.buildProtocolFee(setup.protocolFeeBps, protocolFeeRecipient))
            ) : bytes(""),
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
            threshold: "", // no minimum output
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
        // Just need to rebuild the takerData with signature for swapping
        // Since the original takerData was built for quoting (with empty signature),
        // we need to extract the isExactIn flag first (first two bytes contain flags)
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

    function test_ProtocolFee_Only_ExactIn_ReceivedByRecipient() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // Expected amount should be calculated from amountOut before fee deduction
        // NOTE: swap(...) returns amountOut after fee deduction
        uint256 expectedProtocolFee = (amountOut * setup.protocolFeeBps) / (BPS - setup.protocolFeeBps);
        uint256 actualProtocolFee = TokenMock(tokenB).balanceOf(protocolFeeRecipient);
        assertEq(actualProtocolFee, expectedProtocolFee, "Protocol fee recipient should receive correct fee amount");
    }

    function test_ProtocolFee_Only_ExactOut_ReceivedByRecipient() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountOut = 50e18;
        vm.prank(taker);
        (, uint256 amountOutAfterFee,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactInTakerDataSwap);

        // Expected amount should be calculated from amountOut before fee deduction
        // NOTE: swap(...) returns amountOut after fee deduction
        uint256 expectedProtocolFee = (amountOutAfterFee * setup.protocolFeeBps) / (BPS - setup.protocolFeeBps);
        uint256 actualProtocolFee = TokenMock(tokenB).balanceOf(protocolFeeRecipient);
        uint256 expectedTotalAmountOut = amountOut * BPS / (BPS - setup.protocolFeeBps);

        assertEq(actualProtocolFee, expectedProtocolFee, "Protocol fee recipient should receive correct fee amount");
        assertEq(amountOutAfterFee + actualProtocolFee, expectedTotalAmountOut, "Total amountOut should equal received amountOut plus protocol fee");
    }

    function test_ProtocolFee_ExactIn_WithFlatFeeGivesWorseRate() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0,
            flatOutFeeBps: 0.05e9 // 5% flat fee
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // Fee application order (actual execution order):
        // 1. XYC swap computes rawAmountOut
        // 2. flatFeeOut is applied: afterFlat = rawAmountOut * (1 - flatFee%)
        // 3. protocolFeeOut is applied: amountOut = afterFlat * (1 - protocolFee%)
        //
        // So protocol fee is computed from the amount AFTER flat fee is applied.
        // protocolFee = afterFlat * protocolFee% = amountOut / (1 - protocolFee%) * protocolFee%
        //
        // Simplified: protocolFee = amountOut * protocolFee% / (1 - protocolFee%)

        uint256 expectedProtocolFee = amountOut * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 actualProtocolFee = TokenMock(tokenB).balanceOf(protocolFeeRecipient);

        assertEq(actualProtocolFee, expectedProtocolFee, "Protocol fee recipient should receive correct fee amount");

        // Check that amountOut with only flat fee is greater than amountOut with both fees
        setup.protocolFeeBps = 0;
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);
        (, uint256 amountOutWithOnlyFlatFee,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountIn, exactInTakerData);
        assertGt(amountOutWithOnlyFlatFee, amountOut, "Amount out with only flat fee should be greater than amount out with both fees");
    }

    function test_ProtocolFee_ExactOut_WithFlatFeeGivesWorseRate() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0.05e9, // 5% flat fee
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountOut = 50e18;
        vm.prank(taker);
        (uint256 amountInAfterBothFee, uint256 amountOutAfterBothFee,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactInTakerDataSwap);

        // FlatFee is applied on amountIn for exactOut swaps, ProtocolFee on amountOut
        uint256 expectedFlatFee = (amountInAfterBothFee * setup.flatInFeeBps) / BPS;
        uint256 expectedProtocolFee = (amountOutAfterBothFee * setup.protocolFeeBps) / (BPS - setup.protocolFeeBps);
        uint256 actualProtocolFee = TokenMock(tokenB).balanceOf(protocolFeeRecipient);
        uint256 expectedTotalAmountOut = amountOut * BPS / (BPS - setup.protocolFeeBps);

        assertEq(actualProtocolFee, expectedProtocolFee, "Protocol fee recipient should receive correct fee amount");
        assertEq(amountOutAfterBothFee + actualProtocolFee, expectedTotalAmountOut, "Total amountOut should equal received amountOut plus protocol fee");

        // XYC exactOut(55.555e18) with balances(100e18, 200e18) = 38461538461538461538
        assertEq(amountInAfterBothFee - expectedFlatFee, 38461538461538461538, "Total amountIn should equal paid amountIn plus flat fee");

        // Check that amountIn with only flat fee is less than amountIn with both fees
        setup.protocolFeeBps = 0;
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);
        (uint256 amountInAfterFlatFee,,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountOut, exactInTakerData);
        assertLt(amountInAfterFlatFee, amountInAfterBothFee, "Only flat fee should result in lower amountIn than both fees");
    }

    // ========== Protocol Fee AmountIn Tests ==========

    function test_ProtocolFeeAmountIn_ExactIn_ReceivedByRecipient() public {
        // Creating order with protocol fee on amountIn
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFeeType(setup, true);

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

        // Verify amountOut is less than without fee (due to fee deduction from effective amountIn)
        uint256 noFeeAmountOut = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertLt(amountOut, noFeeAmountOut, "AmountOut should be less with protocol fee on amountIn");
    }

    function test_ProtocolFeeAmountIn_ExactOut_ReceivedByRecipient() public {
        // Creating order with protocol fee on amountIn
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% fee
            flatInFeeBps: 0,
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFeeType(setup, true);

        bytes memory exactOutTakerData = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory exactOutTakerDataSwap = _swappingTakerData(exactOutTakerData, signature);

        uint256 amountOut = 50e18;
        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactOutTakerDataSwap);

        // For ExactOut with protocol fee on amountIn:
        // feeAmount = baseAmountIn * feeBps / (BPS - feeBps)
        // totalAmountIn = baseAmountIn + feeAmount
        uint256 actualProtocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Calculate expected values
        uint256 baseAmountIn = setup.balanceA * amountOut / (setup.balanceB - amountOut);
        uint256 expectedProtocolFee = baseAmountIn * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 expectedTotalAmountIn = baseAmountIn + expectedProtocolFee;

        assertApproxEqAbs(actualProtocolFee, expectedProtocolFee, 1, "Protocol fee recipient should receive correct fee from tokenIn");
        assertApproxEqAbs(actualAmountIn, expectedTotalAmountIn, 1, "Taker should pay amountIn plus protocol fee");
        assertEq(actualAmountOut, amountOut, "AmountOut should match requested amount");
    }

    function test_ProtocolFeeAmountIn_WithFlatFeeIn_ExactIn() public {
        // Creating order with both flat fee and protocol fee on amountIn
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            protocolFeeBps: 0.10e9, // 10% protocol fee
            flatInFeeBps: 0.05e9,  // 5% flat fee
            flatOutFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFeeType(setup, true);

        bytes memory exactInTakerData = _quotingTakerData(TakerSetup({ isExactIn: true }));
        bytes memory exactInTakerDataSwap = _swappingTakerData(exactInTakerData, signature);

        uint256 amountIn = 10e18;
        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerDataSwap);

        // Both fees applied to amountIn
        uint256 protocolFee = TokenMock(tokenA).balanceOf(protocolFeeRecipient);

        // Verify protocol fee was collected (non-zero)
        assertGt(protocolFee, 0, "Protocol fee should be collected");

        // Verify amountOut is less than no-fee swap
        uint256 noFeeAmountOut = setup.balanceB * amountIn / (setup.balanceA + amountIn);
        assertLt(amountOut, noFeeAmountOut, "AmountOut should be less with both fees applied");
    }
}
