// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";
import { ExactInOutSymmetry } from "./invariants/ExactInOutSymmetry.t.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { Debug } from "../src/instructions/Debug.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

uint256 constant ONE = 1e18;

contract FeeTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(0)) {}

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
        uint32 feeInBps;
        uint32 feeOutBps;
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory programBytes = bytes.concat(
            // 1. Set initial token balances
            program.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
            // 2. Apply feeIn (optional)
            setup.feeInBps > 0 ? program.build(Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(setup.feeInBps)) : bytes(""),
            // 3. Apply feeOut (optional)
            setup.feeOutBps > 0 ? program.build(Fee._flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(setup.feeOutBps)) : bytes(""),
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

    function _makeTakerData(TakerSetup memory setup, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: setup.isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "", // no minimum output
            to: address(0),
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

    function test_FeeIn_ExactIn_SwapAndQuoteConsistent() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% fee
            feeOutBps: 0 // no feeOut
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), signature);

        uint256 amountIn = 10e18;

        // Get quote
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn, exactInTakerData);

        // Execute swap
        vm.prank(taker);
        (uint256 swappedAmountIn, uint256 swappedAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerData);

        // Verify quote matches swap
        assertEq(swappedAmountIn, quotedAmountIn, "Swap amountIn should match quote");
        assertEq(swappedAmountOut, quotedAmountOut, "Swap amountOut should match quote");

        // Verify fee calculation correctness
        uint256 effectiveSwapInput = (amountIn * (BPS - setup.feeInBps)) / BPS;
        uint256 expectedOutputWithFee = (effectiveSwapInput * setup.balanceB) / (setup.balanceA + effectiveSwapInput);
        assertEq(swappedAmountOut, expectedOutputWithFee, "Output should reflect fee-in calculation");
    }

    function test_FeeIn_ExactOut_SwapAndQuoteConsistent() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% fee
            feeOutBps: 0 // no feeOut
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), signature);

        uint256 amountOut = 10e18;

        // Get quote
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, exactOutTakerData);

        // Execute swap
        vm.prank(taker);
        (uint256 swappedAmountIn, uint256 swappedAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactOutTakerData);

        // Verify quote matches swap
        assertEq(swappedAmountIn, quotedAmountIn, "Swap amountIn should match quote");
        assertEq(swappedAmountOut, quotedAmountOut, "Swap amountOut should match quote");

        // Verify fee calculation correctness
        uint256 baseInput = (amountOut * setup.balanceA + (setup.balanceB - amountOut - 1)) / (setup.balanceB - amountOut);
        uint256 expectedInputWithFee = baseInput * BPS / (BPS - setup.feeInBps);
        assertEq(swappedAmountIn, expectedInputWithFee, "Input should reflect fee-in calculation");
    }

    /**
     * @dev Test that exactIn and exactOut swaps provide same exchange rate for FEE_IN
     *      This ensures no unexpected benefits for taker choosing one method over another
     */
    function test_FeeIn_ExchangeRateConsistency() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% fee
            feeOutBps: 0 // no feeOut
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        uint256 inputAmount = 10e18;

        // Step 1: ExactIn quoting - input 10e18 tokenA
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 outputFromExactIn,) = swapVM.asView().quote(order, tokenA, tokenB, inputAmount, exactInTakerData);

        // Step 2: ExactOut quoting - request the exact output amount from exactIn
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 inputForExactOut,,) = swapVM.asView().quote(order, tokenA, tokenB, outputFromExactIn, exactOutTakerData);

        // Step 3: Verify the exchange rate is consistent
        assertEq(
            inputForExactOut,
            inputAmount,
            "ExactIn and ExactOut should have same exchange rate for FEE_IN"
        );
    }

    function test_FeeIn_ExchangeRateConsistency_ForLargeAmount() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% fee
            feeOutBps: 0 // no feeOut
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Step 0: ExactOut quoting to get input for output of 100% of balanceB - 1
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 inputAmount,,) = swapVM.asView().quote(order, tokenA, tokenB, setup.balanceB - 1, exactOutTakerData);

        // Step 1: ExactIn quoting
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 outputFromExactIn,) = swapVM.asView().quote(order, tokenA, tokenB, inputAmount, exactInTakerData);

        // Step 2: ExactOut quoting - request the exact output amount from exactIn
        (uint256 inputForExactOut,,) = swapVM.asView().quote(order, tokenA, tokenB, outputFromExactIn, exactOutTakerData);

        // Step 3: Verify the exchange rate is consistent
        assertEq(
            inputForExactOut,
            inputAmount,
            "ExactIn and ExactOut should have same exchange rate for FEE_IN"
        );
    }

    function test_FeeOut_ExactIn_SwapAndQuoteConsistent() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0, // no feeIn
            feeOutBps: 0.10e9 // 10% fee
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), signature);

        uint256 amountIn = 10e18;

        // Get quote
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn, exactInTakerData);

        // Execute swap
        vm.prank(taker);
        (uint256 swappedAmountIn, uint256 swappedAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerData);

        // Verify quote matches swap
        assertEq(swappedAmountIn, quotedAmountIn, "Swap amountIn should match quote");
        assertEq(swappedAmountOut, quotedAmountOut, "Swap amountOut should match quote");

        // Verify fee calculation correctness
        uint256 rawOutput = (amountIn * setup.balanceB) / (setup.balanceA + amountIn);
        uint256 expectedOutputWithFee = rawOutput - rawOutput * setup.feeOutBps / BPS;
        assertEq(swappedAmountOut, expectedOutputWithFee, "Output should reflect fee-out calculation");
    }

    function test_FeeOut_ExactOut_SwapAndQuoteConsistent() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0, // no feeIn
            feeOutBps: 0.10e9 // 10% fee
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), signature);

        uint256 amountOut = 10e18;

        // Get quote
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, exactOutTakerData);

        // Execute swap
        vm.prank(taker);
        (uint256 swappedAmountIn, uint256 swappedAmountOut,) = swapVM.swap(order, tokenA, tokenB, amountOut, exactOutTakerData);

        // Verify quote matches swap
        assertEq(swappedAmountIn, quotedAmountIn, "Swap amountIn should match quote");
        assertEq(swappedAmountOut, quotedAmountOut, "Swap amountOut should match quote");

        // Verify fee calculation correctness
        uint256 rawOutputNeeded = (amountOut * BPS + (BPS - setup.feeOutBps - 1)) / (BPS - setup.feeOutBps);
        uint256 expectedInputForRawOutput = (rawOutputNeeded * setup.balanceA + (setup.balanceB - rawOutputNeeded - 1)) / (setup.balanceB - rawOutputNeeded);
        assertEq(swappedAmountIn, expectedInputForRawOutput, "Input should reflect fee-out calculation");
    }

    /**
     * @dev Test that exactIn and exactOut swaps provide same exchange rate for FEE_OUT
     *      This ensures no unexpected benefits for taker choosing one method over another
     */
    function test_FeeOut_ExchangeRateConsistency() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0, // no feeIn
            feeOutBps: 0.10e9 // 10% fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        uint256 inputAmount = 10e18;

        // Step 1: ExactIn quoting - input 10e18 tokenA
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 outputFromExactIn,) = swapVM.asView().quote(order, tokenA, tokenB, inputAmount, exactInTakerData);

        // Step 2: ExactOut quoting - request the exact output amount from exactIn
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 inputForExactOut,,) = swapVM.asView().quote(order, tokenA, tokenB, outputFromExactIn, exactOutTakerData);

        // Step 3: Verify the exchange rate is consistent
        assertEq(
            inputForExactOut,
            inputAmount,
            "ExactIn and ExactOut should have same exchange rate for FEE_OUT"
        );
    }

    function test_FeeOut_ExchangeRateConsistency_ForLargeAmount() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0, // no feeIn
            feeOutBps: 0.10e9 // 10% fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Step 0: ExactOut quoting - get input for 100% of balance B - fees
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 inputAmount,,) = swapVM.asView().quote(order, tokenA, tokenB, setup.balanceB * (BPS - setup.feeOutBps) / BPS - 1, exactOutTakerData);

        // Step 1: ExactIn quoting
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 outputFromExactIn,) = swapVM.asView().quote(order, tokenA, tokenB, inputAmount, exactInTakerData);

        // Step 2: ExactOut quoting - request the exact output amount from exactIn
        (uint256 inputForExactOut,,) = swapVM.asView().quote(order, tokenA, tokenB, outputFromExactIn, exactOutTakerData);

        // Step 3: Verify the exchange rate is consistent
        assertEq(
            inputForExactOut,
            inputAmount,
            "ExactIn and ExactOut should have same exchange rate for FEE_OUT"
        );
    }

    function test_FeeIn_FeeOut_ConsistentExactInVsExactOut() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% feeIn
            feeOutBps: 0.15e9 // 15% feeOut
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        uint256 inputAmount = 33e18;

        // Step 1: ExactIn quoting - input 10e18 tokenA
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 outputFromExactIn,) = swapVM.asView().quote(order, tokenA, tokenB, inputAmount, exactInTakerData);

        // Step 2: ExactOut quoting - request the exact output amount from exactIn
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 inputForExactOut,,) = swapVM.asView().quote(order, tokenA, tokenB, outputFromExactIn, exactOutTakerData);

        // Step 3: Verify the exchange rate is consistent
        assertEq(
            inputForExactOut * ONE / outputFromExactIn,
            inputAmount * ONE / outputFromExactIn,
            "ExactIn and ExactOut should have same exchange rate for FEE_IN and FEE_OUT applied simultaneously"
        );
    }

    // === Tests using ExactInOutSymmetry library ===

    function test_SymmetryInvariant_FeeIn() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.10e9, // 10% fee
            feeOutBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        ExactInOutSymmetry.assertSymmetryBatch(
            swapVM,
            order,
            tokenA,
            tokenB,
            dynamic([uint256(1e18), 10e18, 50e18]),
            _makeTakerData(TakerSetup({ isExactIn: true }), ""),
            _makeTakerData(TakerSetup({ isExactIn: false }), ""),
            1 // 1 wei tolerance
        );
    }

    function test_SymmetryInvariant_FeeOut() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0,
            feeOutBps: 0.10e9 // 10% fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        ExactInOutSymmetry.assertSymmetryBatch(
            swapVM,
            order,
            tokenA,
            tokenB,
            dynamic([uint256(1e18), 10e18, 50e18]),
            _makeTakerData(TakerSetup({ isExactIn: true }), ""),
            _makeTakerData(TakerSetup({ isExactIn: false }), ""),
            1 // 1 wei tolerance
        );
    }

    function test_SymmetryInvariant_BothFees() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            feeInBps: 0.05e9, // 5% fee in
            feeOutBps: 0.05e9 // 5% fee out
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        ExactInOutSymmetry.assertSymmetryBatch(
            swapVM,
            order,
            tokenA,
            tokenB,
            dynamic([uint256(1e18), 10e18, 50e18]),
            _makeTakerData(TakerSetup({ isExactIn: true }), ""),
            _makeTakerData(TakerSetup({ isExactIn: false }), ""),
            1 // 1 wei tolerance
        );
    }
}
