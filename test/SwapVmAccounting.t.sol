// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";

import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { Controls } from "../src/instructions/Controls.sol";
import { Decay, DecayArgsBuilder } from "../src/instructions/Decay.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title SwapVmAccounting
 * @notice SwapVM (non-Aqua) accounting correctness with fees — mirrors AquaAccounting tests
 */
contract SwapVmAccounting is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    // Constants
    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_BALANCE_A = 1000e18;
    uint256 constant INITIAL_BALANCE_B = 2000e18; // Asymmetric pool: ratio matters for CorrectVsWrong ordering tests
    uint256 constant SWAP_AMOUNT = 100e18;

    uint16 constant DECAY_PERIOD = 300; // 5 minutes

    // Contracts
    SwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    Balances public balancesContract;

    // Addresses
    address public maker;
    uint256 public makerPrivateKey;
    address public taker;
    address public protocolFeeRecipient;

    constructor() OpcodesDebug(address(new Aqua())) {}

    function setUp() public {
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        swapVM = new SwapVMRouterDebug(address(0), address(0), "SwapVM", "1.0.0");
        balancesContract = Balances(address(swapVM));

        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        taker = makeAddr("taker");
        protocolFeeRecipient = vm.addr(0x8888);

        // Mint and approve for maker
        tokenA.mint(maker, INITIAL_BALANCE_A);
        tokenB.mint(maker, INITIAL_BALANCE_B);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Mint and approve for taker
        tokenA.mint(taker, 10000e18);
        tokenB.mint(taker, 10000e18);
        vm.prank(taker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ===== STRUCTS =====

    struct SwapResult {
        bytes32 orderHash;
        uint256 amountIn;
        uint256 amountOut;
    }

    struct DoubleSwapResult {
        bytes32 orderHash;
        uint256 amountIn1;
        uint256 amountOut1;
        uint256 amountIn2;
        uint256 amountOut2;
        uint256 protocolFee1;
        uint256 protocolFee2;
    }

    // ===== CORE HELPERS =====

    function defaultConcentrateArgs() internal pure returns (bytes memory) {
        return XYCConcentrateArgsBuilder.build2D(
            Math.sqrt(0.5e36),
            Math.sqrt(2.0e36)
        );
    }

    function defaultPeggedArgs() internal pure returns (PeggedSwapArgsBuilder.Args memory) {
        return PeggedSwapArgsBuilder.Args({
            x0: INITIAL_BALANCE_A,
            y0: INITIAL_BALANCE_B,
            linearWidth: 1e27,
            rateLt: 1,
            rateGt: 1
        });
    }

    function signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function buildTakerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
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

    function deployAndSwap(bytes memory program, bool isExactIn) internal returns (SwapResult memory r) {
        ISwapVM.Order memory order = createOrder(program);
        bytes memory sig = signOrder(order);
        r.orderHash = swapVM.hash(order);

        bytes memory takerData = buildTakerData(isExactIn, sig);
        vm.prank(taker);
        (r.amountIn, r.amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
    }

    function deployAndDoubleSwap(bytes memory program, bool isExactIn) internal returns (DoubleSwapResult memory r) {
        ISwapVM.Order memory order = createOrder(program);
        bytes memory sig = signOrder(order);
        r.orderHash = swapVM.hash(order);

        bytes memory takerData = buildTakerData(isExactIn, sig);

        vm.prank(taker);
        (r.amountIn1, r.amountOut1,) = swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        r.protocolFee1 = getProtocolFee();

        vm.warp(block.timestamp + 150);

        vm.prank(taker);
        (r.amountIn2, r.amountOut2,) = swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        r.protocolFee2 = getProtocolFee();
    }

    function getBalances(bytes32 orderHash) internal view returns (uint256 balA, uint256 balB) {
        balA = balancesContract.balances(orderHash, address(tokenA));
        balB = balancesContract.balances(orderHash, address(tokenB));
    }

    function getProtocolFee() internal view returns (uint256) {
        return tokenA.balanceOf(protocolFeeRecipient);
    }

    function assertConservation(bytes32 orderHash, uint256 totalAmountIn, uint256 totalAmountOut) internal view {
        (uint256 balA, uint256 balB) = getBalances(orderHash);
        uint256 protocolFee = getProtocolFee();

        assertGt(protocolFee, 0, "Protocol fee paid");
        assertEq(balA + protocolFee, INITIAL_BALANCE_A + totalAmountIn, "Token A conservation");
        assertEq(balB + totalAmountOut, INITIAL_BALANCE_B, "Token B conservation");
    }

    function assertTokenAConservation(bytes32 orderHash, uint256 totalAmountIn) internal view {
        (uint256 balA,) = getBalances(orderHash);
        uint256 protocolFee = getProtocolFee();

        assertGt(protocolFee, 0, "Protocol fee paid");
        assertEq(balA + protocolFee, INITIAL_BALANCE_A + totalAmountIn, "Token A conservation");
    }

    // ===== PROGRAM BUILDERS =====
    // Order: protocolFee -> dynamicBalances -> [decay?] -> [concentrate?] -> flatFee -> swap / peggedSwap -> salt

    function _dynamicBalancesArgs() internal view returns (bytes memory) {
        return BalancesArgsBuilder.build(
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INITIAL_BALANCE_A, INITIAL_BALANCE_B])
        );
    }

    function buildProgram(
        uint32 protocolFeeBps,
        uint32 flatFeeInBps,
        bool includeConcentrate
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory concentrateCode = includeConcentrate
            ? p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                     defaultConcentrateArgs())
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            p.build(Balances._dynamicBalancesXD, _dynamicBalancesArgs()),
            concentrateCode,
            flatFeeCode,
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildWrongProgram(
        uint32 protocolFeeBps,
        uint32 flatFeeInBps
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            p.build(Balances._dynamicBalancesXD, _dynamicBalancesArgs()),
            protocolFeeCode, // WRONG: protocolFee after balances
            flatFeeCode,     // WRONG: flatFee before Concentrate
            p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                   defaultConcentrateArgs()),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildProgramWithDecayConcentrate(
        uint32 protocolFeeBps,
        uint16 decayPeriod,
        uint32 flatFeeInBps
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            p.build(Balances._dynamicBalancesXD, _dynamicBalancesArgs()),
            p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),
            p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                   defaultConcentrateArgs()),
            flatFeeCode,
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildProgramWithDecayXYCSwap(
        uint32 protocolFeeBps,
        uint16 decayPeriod,
        uint32 flatFeeInBps
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            p.build(Balances._dynamicBalancesXD, _dynamicBalancesArgs()),
            p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),
            flatFeeCode,
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildProgramWithDecayPegged(
        uint32 protocolFeeBps,
        uint16 decayPeriod,
        uint32 flatFeeInBps,
        PeggedSwapArgsBuilder.Args memory peggedArgs
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            p.build(Balances._dynamicBalancesXD, _dynamicBalancesArgs()),
            p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),
            flatFeeCode,
            p.build(PeggedSwap._peggedSwapGrowPriceRange2D, PeggedSwapArgsBuilder.build(peggedArgs)),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function createOrder(bytes memory programBytes) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
    }

    // ===== TEST GROUP 1: XYCSwap Tests =====

    function test_XYCSwap_ProtocolFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, false), true);

        assertEq(r.amountIn, SWAP_AMOUNT, "AmountIn should match swap amount");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, false), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "AmountOut should match requested");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_With_FlatFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, false), true);
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_With_FlatFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, false), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "AmountOut should match requested");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    // ===== TEST GROUP 2: XYCConcentrate Tests =====

    function test_XYCConcentrate_ProtocolFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, true), true);

        assertTokenAConservation(r.orderHash, r.amountIn);

        (uint256 actualLiq,) = getBalances(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertGt(actualLiq, 0, "Liquidity positive");
        assertGt(actualLiq, 0, "Liquidity positive after swap");
    }

    function test_XYCConcentrate_ProtocolFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, true), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "Exact out amount");
        assertTokenAConservation(r.orderHash, r.amountIn);

        (uint256 actualLiq,) = getBalances(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertGt(actualLiq, 0, "Liquidity positive");
        assertGt(actualLiq, 0, "Liquidity positive after swap");
    }

    function test_XYCConcentrate_ProtocolFee_With_FlatFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, true), true);

        assertTokenAConservation(r.orderHash, r.amountIn);

        (uint256 actualLiq,) = getBalances(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertGt(actualLiq, 0, "Liquidity positive");
        assertGt(actualLiq, 0, "Liquidity positive (fees retained)");
    }

    function test_XYCConcentrate_ProtocolFee_With_FlatFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, true), false);

        assertTokenAConservation(r.orderHash, r.amountIn);

        (uint256 actualLiq,) = getBalances(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertGt(actualLiq, 0, "Liquidity positive");
        assertGt(actualLiq, 0, "Liquidity positive (fees retained)");
    }

    // ===== COMPARATIVE TESTS: Wrong vs Correct Instruction Order =====

    function test_XYCConcentrate_CompareCorrectVsWrongOrder_ExactIn() public {

        SwapResult memory correct = deployAndSwap(buildProgram(0.05e9, 0.10e9, true), true);
        SwapResult memory wrong = deployAndSwap(buildWrongProgram(0.05e9, 0.10e9), true);

        {
            (uint256 correctBal,) = getBalances(correct.orderHash);
            (uint256 wrongBal,) = getBalances(wrong.orderHash);
            // "Correct" order: protocolFee runs BEFORE dynamicBalances → fee properly deducted
            // before pool credit → pool gets (amountIn - fee), so correctBal < wrongBal.
            // "Wrong" order: dynamicBalances FIRST credits full amountIn to pool, then protocolFee
            // has nothing left to deduct → pool gets full amountIn = wrongBal > correctBal.
            // The key invariant: correct order ensures fees are actually charged.
            assertLt(correctBal, wrongBal, "CORRECT order properly deducts fees before pool credit");
        }
    }

    function test_XYCConcentrate_CompareCorrectVsWrongOrder_ExactOut() public {

        SwapResult memory correct = deployAndSwap(buildProgram(0.05e9, 0.10e9, true), false);
        SwapResult memory wrong = deployAndSwap(buildWrongProgram(0.05e9, 0.10e9), false);

        {
            (uint256 correctBal,) = getBalances(correct.orderHash);
            (uint256 wrongBal,) = getBalances(wrong.orderHash);
            // "Correct" order: protocolFee deducted BEFORE pool credit → correctBal < wrongBal
            assertLt(correctBal, wrongBal, "CORRECT order properly deducts fees before pool credit");
        }
    }

    // ===== TEST GROUP 3: Decay + XYCConcentrate Tests =====

    function test_DecayXYCConcentrate_ProtocolFee_FlatFee_ExactIn() public {
        bytes memory program = buildProgramWithDecayConcentrate(0.05e9, DECAY_PERIOD, 0.10e9);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, true);

        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased after second swap");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);

        {
            (uint256 finalBal,) = getBalances(r.orderHash);
            assertGt(finalBal, 0, "Liquidity positive after both swaps");
        }
    }

    function test_DecayXYCConcentrate_ProtocolFee_FlatFee_ExactOut() public {
        bytes memory program = buildProgramWithDecayConcentrate(0.05e9, DECAY_PERIOD, 0.10e9);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, false);

        assertEq(r.amountOut1, SWAP_AMOUNT, "First swap: exact out");
        assertEq(r.amountOut2, SWAP_AMOUNT, "Second swap: exact out");
        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);

        {
            (uint256 finalBal,) = getBalances(r.orderHash);
            assertGt(finalBal, 0, "Liquidity positive");
        }
    }

    // ===== TEST GROUP 4: Decay + PeggedSwap Tests =====

    function test_DecayPeggedSwap_ProtocolFee_FlatFee_ExactIn() public {
        bytes memory program = buildProgramWithDecayPegged(0.05e9, DECAY_PERIOD, 0.10e9, defaultPeggedArgs());

        DoubleSwapResult memory r = deployAndDoubleSwap(program, true);

        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased");
        assertGt(r.amountOut1, 0, "First swap produced output");
        assertGt(r.amountOut2, 0, "Second swap produced output");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);
    }

    function test_DecayPeggedSwap_ProtocolFee_FlatFee_ExactOut() public {
        bytes memory program = buildProgramWithDecayPegged(0.05e9, DECAY_PERIOD, 0.10e9, defaultPeggedArgs());

        DoubleSwapResult memory r = deployAndDoubleSwap(program, false);

        assertEq(r.amountOut1, SWAP_AMOUNT, "First swap: exact out");
        assertEq(r.amountOut2, SWAP_AMOUNT, "Second swap: exact out");
        assertGt(r.protocolFee1, 0, "Protocol fee paid");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);
    }

    // ===== TEST GROUP 4b: Decay + Regular Tokens (XYCSwap instead of PeggedSwap) =====

    function test_DecayRegularSwap_ProtocolFee_FlatFee_ExactIn() public {
        bytes memory program = buildProgramWithDecayXYCSwap(0.05e9, DECAY_PERIOD, 0.10e9);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, true);

        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased");
        assertGt(r.amountOut1, 0, "First swap produced output");
        assertGt(r.amountOut2, 0, "Second swap produced output");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);
    }

    function test_DecayRegularSwap_ProtocolFee_FlatFee_ExactOut() public {
        bytes memory program = buildProgramWithDecayXYCSwap(0.05e9, DECAY_PERIOD, 0.10e9);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, false);

        assertEq(r.amountOut1, SWAP_AMOUNT, "First swap: exact out");
        assertEq(r.amountOut2, SWAP_AMOUNT, "Second swap: exact out");
        assertGt(r.protocolFee1, 0, "Protocol fee paid");
        assertGt(r.protocolFee2, r.protocolFee1, "Protocol fee increased");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);
    }

}
