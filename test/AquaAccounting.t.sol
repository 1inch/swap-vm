// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "./mocks/MockTaker.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { AquaOpcodesDebug } from "../src/opcodes/AquaOpcodesDebug.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";

import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { Controls } from "../src/instructions/Controls.sol";
import { Decay, DecayArgsBuilder } from "../src/instructions/Decay.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title AquaAccounting
 * @notice Minimalistic POC to prove Aqua accounting correctness with fees
 */
contract AquaAccounting is Test, AquaOpcodesDebug {
    using ProgramBuilder for Program;

    // Constants
    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_BALANCE_A = 1000e18;
    uint256 constant INITIAL_BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 100e18;

    uint256 constant PROTOCOL_FEE_BPS = 0.05e9; // 5%
    uint256 constant FLAT_FEE_BPS = 0.10e9; // 10%
    uint16 constant DECAY_PERIOD = 300; // 5 minutes in seconds

    // Contracts
    Aqua public immutable aqua = new Aqua();
    AquaSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    XYCConcentrate public concentrate;
    Decay public decay;
    PeggedSwap public peggedSwap;

    // Addresses
    address public maker;
    uint256 public makerPrivateKey;
    MockTaker public taker;
    address public protocolFeeRecipient;

    constructor() AquaOpcodesDebug(address(aqua)) {}

    function setUp() public {
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        swapVM = new AquaSwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        concentrate = XYCConcentrate(address(swapVM));
        decay = Decay(address(swapVM));
        peggedSwap = PeggedSwap(address(swapVM));

        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        taker = new MockTaker(aqua, swapVM, address(this));

        protocolFeeRecipient = vm.addr(0x8888);
    }

    // ===== STRUCTS =====

    struct SwapResult {
        bytes32 orderHash;
        ISwapVM.Order order;
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

    /// @notice Compute concentrate deltas with default ±50% price range
    function defaultConcentrateDeltas() internal pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity) {
        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A;
        return XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A, INITIAL_BALANCE_B, price, price * 50 / 100, price * 150 / 100
        );
    }

    /// @notice Default PeggedSwap args for tokenA/tokenB (both 18 decimals)
    function defaultPeggedArgs() internal pure returns (PeggedSwapArgsBuilder.Args memory) {
        return PeggedSwapArgsBuilder.Args({
            x0: INITIAL_BALANCE_A,
            y0: INITIAL_BALANCE_B,
            linearWidth: 1e27,
            rateLt: 1,
            rateGt: 1
        });
    }

    /// @notice Deploy order (create + ship) and perform a single swap
    function deployAndSwap(
        bytes memory program,
        bool isExactIn
    ) internal returns (SwapResult memory r) {
        r.order = createOrder(program);
        r.orderHash = shipStrategy(r.order);
        (r.amountIn, r.amountOut) = performSwap(r.order, SWAP_AMOUNT, true, isExactIn);
    }

    /// @notice Deploy order and perform two swaps with time warp between them (for Decay tests)
    function deployAndDoubleSwap(
        bytes memory program,
        bool isExactIn
    ) internal returns (DoubleSwapResult memory r) {
        ISwapVM.Order memory order = createOrder(program);
        r.orderHash = shipStrategy(order);

        (r.amountIn1, r.amountOut1) = performSwap(order, SWAP_AMOUNT, true, isExactIn);
        r.protocolFee1 = tokenA.balanceOf(protocolFeeRecipient);

        vm.warp(block.timestamp + 150); // 2.5 minutes

        (r.amountIn2, r.amountOut2) = performSwap(order, SWAP_AMOUNT, true, isExactIn);
        r.protocolFee2 = tokenA.balanceOf(protocolFeeRecipient);
    }

    /// @notice Get Aqua balances for the strategy
    function getAquaBalances(bytes32 orderHash) internal view returns (uint256 balA, uint256 balB) {
        return aqua.safeBalances(maker, address(swapVM), orderHash, address(tokenA), address(tokenB));
    }

    /// @notice Get protocol fee (tokenA balance of recipient)
    function getProtocolFee() internal view returns (uint256) {
        return tokenA.balanceOf(protocolFeeRecipient);
    }

    /// @notice Assert conservation laws for both tokens
    function assertConservation(
        bytes32 orderHash,
        uint256 totalAmountIn,
        uint256 totalAmountOut
    ) internal view {
        (uint256 aquaBalA, uint256 aquaBalB) = getAquaBalances(orderHash);
        uint256 protocolFee = getProtocolFee();

        assertGt(protocolFee, 0, "Protocol fee paid");
        assertEq(aquaBalA + protocolFee, INITIAL_BALANCE_A + totalAmountIn, "Token A conservation");
        assertEq(aquaBalB + totalAmountOut, INITIAL_BALANCE_B, "Token B conservation");
    }

    /// @notice Assert Token A conservation only (for tests that check Token B separately)
    function assertTokenAConservation(
        bytes32 orderHash,
        uint256 totalAmountIn
    ) internal view {
        (uint256 aquaBalA,) = getAquaBalances(orderHash);
        uint256 protocolFee = getProtocolFee();

        assertGt(protocolFee, 0, "Protocol fee paid");
        assertEq(aquaBalA + protocolFee, INITIAL_BALANCE_A + totalAmountIn, "Token A conservation");
    }

    // ===== PROGRAM BUILDERS =====

    function buildProgram(
        uint32 protocolFeeBps,
        uint32 flatFeeInBps,
        bool includeConcentrate,
        uint256 deltaA,
        uint256 deltaB,
        uint256 liquidity
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        bytes memory concentrateCode = includeConcentrate
            ? p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                     XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            concentrateCode,
            flatFeeCode,
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildWrongProgram(
        uint32 protocolFeeBps,
        uint32 flatFeeInBps,
        uint256 deltaA,
        uint256 deltaB,
        uint256 liquidity
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            flatFeeCode,     // WRONG: flatFee before Concentrate
            p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                   XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function buildProgramWithDecayConcentrate(
        uint32 protocolFeeBps,
        uint16 decayPeriod,
        uint32 flatFeeInBps,
        uint256 deltaA,
        uint256 deltaB,
        uint256 liquidity
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
            p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),
            p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                   XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity)),
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
            ? p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        return bytes.concat(
            protocolFeeCode,
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
            useAquaInsteadOfSignature: true,
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

    function shipStrategy(ISwapVM.Order memory order) internal returns (bytes32) {
        bytes32 orderHash = swapVM.hash(order);

        vm.prank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(aqua), type(uint256).max);

        tokenA.mint(maker, INITIAL_BALANCE_A);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INITIAL_BALANCE_A, INITIAL_BALANCE_B])
        );

        assertEq(strategyHash, orderHash, "Strategy hash mismatch");
        return strategyHash;
    }

    function performSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool zeroForOne,
        bool isExactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = zeroForOne
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
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

        TokenMock(tokenIn).mint(address(taker), amount * 2);
        return taker.swap(order, tokenIn, tokenOut, amount, takerData);
    }

    // ===== TEST GROUP 1: XYCSwap Tests =====

    function test_XYCSwap_ProtocolFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, false, 0, 0, 0), true);

        assertEq(r.amountIn, SWAP_AMOUNT, "AmountIn should match swap amount");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, false, 0, 0, 0), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "AmountOut should match requested");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_With_FlatFee_ExactIn() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, false, 0, 0, 0), true);
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    function test_XYCSwap_ProtocolFee_With_FlatFee_ExactOut() public {
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, false, 0, 0, 0), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "AmountOut should match requested");
        assertConservation(r.orderHash, r.amountIn, r.amountOut);
    }

    // ===== TEST GROUP 2: XYCConcentrate Tests =====

    function test_XYCConcentrate_ProtocolFee_ExactIn() public {
        (uint256 deltaA, uint256 deltaB, uint256 initLiq) = defaultConcentrateDeltas();
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, true, deltaA, deltaB, initLiq), true);

        assertTokenAConservation(r.orderHash, r.amountIn);

        uint256 actualLiq = concentrate.liquidity(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertEq(actualLiq, Math.sqrt((INITIAL_BALANCE_A + deltaA + r.amountIn - protocolFee) * (INITIAL_BALANCE_B + deltaB - r.amountOut)), "Liquidity formula");
        assertEq(actualLiq, initLiq, "Liquidity unchanged (correct order)");
    }

    function test_XYCConcentrate_ProtocolFee_ExactOut() public {
        (uint256 deltaA, uint256 deltaB, uint256 initLiq) = defaultConcentrateDeltas();
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0, true, deltaA, deltaB, initLiq), false);

        assertEq(r.amountOut, SWAP_AMOUNT, "Exact out amount");
        assertTokenAConservation(r.orderHash, r.amountIn);

        uint256 actualLiq = concentrate.liquidity(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertEq(actualLiq, Math.sqrt((INITIAL_BALANCE_A + deltaA + r.amountIn - protocolFee) * (INITIAL_BALANCE_B + deltaB - r.amountOut)), "Liquidity formula");
        assertEq(actualLiq, initLiq, "Liquidity unchanged (correct order)");
    }

    function test_XYCConcentrate_ProtocolFee_With_FlatFee_ExactIn() public {
        (uint256 deltaA, uint256 deltaB, uint256 initLiq) = defaultConcentrateDeltas();
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, true, deltaA, deltaB, initLiq), true);

        assertTokenAConservation(r.orderHash, r.amountIn);

        uint256 actualLiq = concentrate.liquidity(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertEq(actualLiq, Math.sqrt((INITIAL_BALANCE_A + deltaA + r.amountIn - protocolFee) * (INITIAL_BALANCE_B + deltaB - r.amountOut)), "Liquidity formula");
        assertGt(actualLiq, initLiq, "Liquidity grew (flat fee retained)");
    }

    function test_XYCConcentrate_ProtocolFee_With_FlatFee_ExactOut() public {
        (uint256 deltaA, uint256 deltaB, uint256 initLiq) = defaultConcentrateDeltas();
        SwapResult memory r = deployAndSwap(buildProgram(0.05e9, 0.10e9, true, deltaA, deltaB, initLiq), false);

        assertTokenAConservation(r.orderHash, r.amountIn);

        uint256 actualLiq = concentrate.liquidity(r.orderHash);
        uint256 protocolFee = getProtocolFee();
        assertEq(actualLiq, Math.sqrt((INITIAL_BALANCE_A + deltaA + r.amountIn - protocolFee) * (INITIAL_BALANCE_B + deltaB - r.amountOut)), "Liquidity formula");
        assertGt(actualLiq, initLiq, "Liquidity grew (flat fee retained)");
    }

    // ===== COMPARATIVE TESTS: Wrong vs Correct Instruction Order =====

    function test_XYCConcentrate_CompareCorrectVsWrongOrder_ExactIn() public {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = defaultConcentrateDeltas();

        SwapResult memory correct = deployAndSwap(buildProgram(0.05e9, 0.10e9, true, deltaA, deltaB, liq), true);
        SwapResult memory wrong = deployAndSwap(buildWrongProgram(0.05e9, 0.10e9, deltaA, deltaB, liq), true);

        assertGt(
            concentrate.liquidity(correct.orderHash),
            concentrate.liquidity(wrong.orderHash),
            "CORRECT order produces MORE liquidity (ExactIn)"
        );
    }

    function test_XYCConcentrate_CompareCorrectVsWrongOrder_ExactOut() public {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = defaultConcentrateDeltas();

        SwapResult memory correct = deployAndSwap(buildProgram(0.05e9, 0.10e9, true, deltaA, deltaB, liq), false);
        SwapResult memory wrong = deployAndSwap(buildWrongProgram(0.05e9, 0.10e9, deltaA, deltaB, liq), false);

        assertGt(
            concentrate.liquidity(correct.orderHash),
            concentrate.liquidity(wrong.orderHash),
            "CORRECT order produces MORE liquidity (ExactOut)"
        );
    }

    // ===== TEST GROUP 3: Decay + XYCConcentrate Tests =====

    function test_DecayXYCConcentrate_ProtocolFee_FlatFee_ExactIn() public {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = defaultConcentrateDeltas();
        bytes memory program = buildProgramWithDecayConcentrate(0.05e9, DECAY_PERIOD, 0.10e9, deltaA, deltaB, liq);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, true);

        // Accounting
        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Collected Protocol fee increased after second swap");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);

        // Liquidity check after first swap (need to replay — use intermediate check via orderHash)
        // After both swaps, liquidity should be positive and growing
        assertGt(concentrate.liquidity(r.orderHash), 0, "Liquidity positive after both swaps");
    }

    function test_DecayXYCConcentrate_ProtocolFee_FlatFee_ExactOut() public {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = defaultConcentrateDeltas();
        bytes memory program = buildProgramWithDecayConcentrate(0.05e9, DECAY_PERIOD, 0.10e9, deltaA, deltaB, liq);

        DoubleSwapResult memory r = deployAndDoubleSwap(program, false);

        assertEq(r.amountOut1, SWAP_AMOUNT, "First swap: exact out");
        assertEq(r.amountOut2, SWAP_AMOUNT, "Second swap: exact out");
        assertGt(r.protocolFee1, 0, "Protocol fee after first swap");
        assertGt(r.protocolFee2, r.protocolFee1, "Collected Protocol fee increased");
        assertConservation(r.orderHash, r.amountIn1 + r.amountIn2, r.amountOut1 + r.amountOut2);

        assertGt(concentrate.liquidity(r.orderHash), 0, "Liquidity positive");
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
}
