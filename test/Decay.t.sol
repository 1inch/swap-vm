// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Decay, DecayArgsBuilder } from "../src/instructions/Decay.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract DecayTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public trader1 = makeAddr("trader1");
    address public trader2 = makeAddr("trader2");
    address public mevBot = makeAddr("mevBot");

    // Test parameters
    uint16 constant DECAY_PERIOD = 300; // 5 minutes
    uint256 constant INITIAL_LIQUIDITY = 1000e18;
    uint256 constant STANDARD_SWAP = 100e18;
    uint256 constant TOLERANCE = 0.01e18; // 1%

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 10000e18);
        TokenMock(tokenB).mint(maker, 10000e18);
        TokenMock(tokenA).mint(trader1, 10000e18);
        TokenMock(tokenB).mint(trader1, 10000e18);
        TokenMock(tokenA).mint(trader2, 10000e18);
        TokenMock(tokenB).mint(trader2, 10000e18);
        TokenMock(tokenA).mint(mevBot, 10000e18);
        TokenMock(tokenB).mint(mevBot, 10000e18);

        // Approve SwapVM
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(trader1);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(trader1);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(trader2);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(trader2);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(mevBot);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(mevBot);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    uint256 private orderNonce = 0;

    function createDecayOrder() internal returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(dynamic([tokenA, tokenB]), dynamic([INITIAL_LIQUIDITY, INITIAL_LIQUIDITY]))),
            p.build(Decay._decayXD,
                DecayArgsBuilder.build(DECAY_PERIOD)),
            p.build(XYCSwap._xycSwapXD, ""),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(uint32(0x1000 + orderNonce++)))
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

        return (order, signature);
    }

    function executeSwap(
        address trader,
        ISwapVM.Order memory order,
        bytes memory signature,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 actualAmountIn, uint256 actualAmountOut) {
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: trader,
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
        }));

        vm.prank(trader);
        (actualAmountIn, actualAmountOut,) = swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amountIn,
            takerData
        );

        return (actualAmountIn, actualAmountOut);
    }

    // Test 1: Basic direction scenarios
    function test_BasicDirections() public {
        (ISwapVM.Order memory order, bytes memory signature) = createDecayOrder();

        // First swap A->B
        (uint256 in1, uint256 out1) = executeSwap(
            trader1,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            STANDARD_SWAP
        );

        // Calculate rate
        uint256 rate1 = (out1 * 1e18) / in1;

        // Expected rate for 100:1000 swap in 1000:1000 strategy
        // out = 100 * 1000 / (1000 + 100) = 90.909...
        uint256 expectedOut1 = (STANDARD_SWAP * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + STANDARD_SWAP);
        uint256 expectedRate1 = (expectedOut1 * 1e18) / STANDARD_SWAP;

        assertApproxEqRel(rate1, expectedRate1, TOLERANCE, "First swap should have normal AMM rate");

        // === Test same direction (A->B again) - NO PENALTY ===
        (, uint256 out2) = executeSwap(
            trader2,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            50e18 // smaller swap
        );

        // After first swap: strategy is 1100:909
        // Expected for 50 A->B: out = 50 * 909 / (1100 + 50) = 39.52...
        uint256 expectedOut2 = (uint256(50e18) * 909) / 1150;
        assertApproxEqRel(out2, expectedOut2, TOLERANCE, "Same direction should have NO penalty");

        // === Test opposite direction (B->A) - WITH PENALTY ===
        (ISwapVM.Order memory order2, bytes memory signature2) = createDecayOrder();

        // First swap A->B
        executeSwap(trader1, order2, signature2, address(tokenA), address(tokenB), STANDARD_SWAP);

        // Opposite direction B->A
        (, uint256 outOpp) = executeSwap(
            trader2,
            order2,
            signature2,
            address(tokenB),
            address(tokenA),
            50e18
        );

        // Normal expected without decay: out = 50 * 1100 / (909 + 50) = 57.35...
        uint256 expectedNormal = (uint256(50e18) * 1100) / 959;

        // With decay penalty, actual output should be less
        assertTrue(outOpp < expectedNormal, "Opposite direction MUST have penalty");

        // Verify penalty is significant (>10%)
        uint256 penalty = ((expectedNormal - outOpp) * 100) / expectedNormal;
        assertTrue(penalty > 10, "Penalty should be > 10%");
    }

    // Test 2: Decay over time
    function test_DecayOverTime() public {
        // We need fresh orders for each time test to avoid offset accumulation

        // Test 1: Immediate penalty
        (ISwapVM.Order memory order1, bytes memory signature1) = createDecayOrder();
        executeSwap(trader1, order1, signature1, address(tokenA), address(tokenB), STANDARD_SWAP);
        (uint256 inImmediate, uint256 outImmediate) = executeSwap(
            trader2,
            order1,
            signature1,
            address(tokenB),
            address(tokenA),
            50e18
        );
        uint256 rateImmediate = (outImmediate * 1e18) / inImmediate;

        // Test 2: Half decay (150 seconds)
        (ISwapVM.Order memory order2, bytes memory signature2) = createDecayOrder();
        executeSwap(trader1, order2, signature2, address(tokenA), address(tokenB), STANDARD_SWAP);

        vm.warp(block.timestamp + DECAY_PERIOD / 2);

        (uint256 inHalf, uint256 outHalf) = executeSwap(
            trader2,
            order2,
            signature2,
            address(tokenB),
            address(tokenA),
            50e18
        );
        uint256 rateHalf = (outHalf * 1e18) / inHalf;

        // Test 3: Full decay (301 seconds)
        (ISwapVM.Order memory order3, bytes memory signature3) = createDecayOrder();
        executeSwap(trader1, order3, signature3, address(tokenA), address(tokenB), STANDARD_SWAP);

        vm.warp(block.timestamp + DECAY_PERIOD + 1);

        (uint256 inFull, uint256 outFull) = executeSwap(
            trader2,
            order3,
            signature3,
            address(tokenB),
            address(tokenA),
            50e18
        );
        uint256 rateFull = (outFull * 1e18) / inFull;

        // Verify decay progression
        assertTrue(rateImmediate < rateHalf, "Rate should improve at half decay");
        assertTrue(rateHalf < rateFull, "Rate should be best after full decay");

        // After full decay, should be close to normal AMM rate
        // Strategy state has changed, but rate should be significantly better
        assertTrue(rateFull > rateImmediate * 11 / 10, "Full decay rate should be >10% better than immediate");
    }

    // Test 3: MEV Protection (Sandwich Attack)
    function test_MEVSandwichProtection() public {
        (ISwapVM.Order memory order, bytes memory signature) = createDecayOrder();

        uint256 mevInitialBalance = TokenMock(tokenA).balanceOf(mevBot);

        // MEV Bot front-runs with large A->B swap
        (uint256 mevIn1, uint256 mevOut1) = executeSwap(
            mevBot,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            200e18 // Large front-run
        );

        // Victim swaps A->B (same direction, no penalty)
        (, uint256 victimOut) = executeSwap(
            trader1,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            50e18
        );

        // Verify victim gets reasonable rate (no penalty for same direction)
        // After 200 swap: strategy is ~1200:833
        // Expected for 50: out = 50 * 833 / (1200 + 50) = 33.32
        uint256 expectedVictimOut = (uint256(50e18) * 833) / 1250;
        assertApproxEqRel(victimOut, expectedVictimOut, TOLERANCE * 2, "Victim should get normal rate");

        // MEV Bot back-runs with B->A (opposite direction, PENALIZED)
        executeSwap(
            mevBot,
            order,
            signature,
            address(tokenB),
            address(tokenA),
            mevOut1 // Try to swap back all B
        );

        uint256 mevFinalBalance = TokenMock(tokenA).balanceOf(mevBot);

        // MEV Bot MUST lose money
        assertTrue(mevFinalBalance < mevInitialBalance, "MEV bot MUST lose money on sandwich");

        // Calculate loss
        uint256 loss = mevInitialBalance - mevFinalBalance;
        uint256 lossPercent = (loss * 100) / mevIn1;

        // Loss should be significant
        assertTrue(lossPercent > 5, "MEV loss should be > 5%");
    }
}
