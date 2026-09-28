// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import {console} from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../../contracts/SwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { Decay } from "../../contracts/instructions/Decay.sol";
import { XYCSwap } from "../../contracts/instructions/XYCSwap.sol";
import { Salt } from "../../contracts/instructions/Controls.sol";


contract DecayTest is Test, OpcodesDebug {
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

    // By default foundry's `block.timestamp` returns 1. We prefer to use realistic one.
    uint40 constant DECAY_REALISTIC_START_TS = 0x123456;

    function setUp() public {
        vm.warp(DECAY_REALISTIC_START_TS);

        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token I", "TKI"));
        tokenB = address(new TokenMock("Token J", "TKJ"));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

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
        return createDecayOrder(DECAY_PERIOD);
    }

    function createDecayOrder(uint16 period) internal returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            DynamicBalances.build(INITIAL_LIQUIDITY, INITIAL_LIQUIDITY),
            Decay.build(period),
            XYCSwap.build(),
            Salt.build(uint32(0x1000 + orderNonce++))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
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
        bool isAToB = tokenIn < tokenOut;
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: trader,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: false,
            usePermit2: false,
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

        // Unpenalized reverse (offsets expired): out = 50 * 1100 / (909.09... + 50) ≈ 57.35
        uint256 outFirst = (STANDARD_SWAP * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + STANDARD_SWAP);
        uint256 balanceAAfter = INITIAL_LIQUIDITY + STANDARD_SWAP;
        uint256 balanceBAfter = INITIAL_LIQUIDITY - outFirst;
        uint256 expectedNormal = (uint256(50e18) * balanceAAfter) / (balanceBAfter + 50e18);

        // Same-block reverse: both offsets apply in full, virtual reserves back to (1000, 1000)
        uint256 expectedPenalized = (uint256(50e18) * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + 50e18);

        assertTrue(outOpp < expectedNormal, "Opposite direction MUST have penalty");
        assertApproxEqRel(outOpp, expectedPenalized, TOLERANCE, "Same-block reverse restores virtual (x, y)");
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

        // After A→B of STANDARD_SWAP: actual (1100, 1000-outFirst), A.asOutput=dx, B.asInput=outFirst.
        // Reverse B→A of 50 applies remaining: virtualA = 1100 - f*dx, virtualB = 1000 - (1-f)*outFirst.
        uint256 outFirst = (STANDARD_SWAP * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + STANDARD_SWAP);
        uint256 reverseIn = 50e18;

        // Immediate (f=1): virtual reserves back to (1000, 1000)
        uint256 expectedImmediate = (reverseIn * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + reverseIn);

        // Half (f=1/2): virtualA = 1050, virtualB = 1000 - outFirst/2
        uint256 expectedHalf = (reverseIn * (INITIAL_LIQUIDITY + STANDARD_SWAP / 2))
            / (INITIAL_LIQUIDITY - outFirst / 2 + reverseIn);

        // Full (f=0): offsets expired, plain AMM on actual reserves
        uint256 expectedFull = (reverseIn * (INITIAL_LIQUIDITY + STANDARD_SWAP))
            / (INITIAL_LIQUIDITY - outFirst + reverseIn);

        assertApproxEqRel(outImmediate, expectedImmediate, TOLERANCE, "Immediate reverse restores virtual (x, y)");
        assertApproxEqRel(outHalf, expectedHalf, TOLERANCE, "Half decay applies half of both offsets");
        assertApproxEqRel(outFull, expectedFull, TOLERANCE, "Full decay should restore the unpenalized AMM rate");
    }

    function test_Decay_OppositeDirectionDoesNotRestartDecay() public {
        (ISwapVM.Order memory order, bytes memory signature) = createDecayOrder();
        uint256 reverseIn = 50e18;
        uint256 outFirst = (STANDARD_SWAP * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + STANDARD_SWAP);

        executeSwap(trader1, order, signature, address(tokenA), address(tokenB), STANDARD_SWAP);

        vm.warp(block.timestamp + DECAY_PERIOD / 2);

        uint256 remDx = STANDARD_SWAP * (DECAY_PERIOD / 2) / DECAY_PERIOD;
        uint256 remDy = outFirst * (DECAY_PERIOD / 2) / DECAY_PERIOD;
        uint256 virtualA1 = INITIAL_LIQUIDITY + STANDARD_SWAP - remDx;
        uint256 virtualB1 = INITIAL_LIQUIDITY - outFirst + remDy;
        uint256 expectedRev1 = (reverseIn * virtualA1) / (virtualB1 + reverseIn);

        (, uint256 outRev1) = executeSwap(
            trader2, order, signature, address(tokenB), address(tokenA), reverseIn
        );
        assertApproxEqRel(outRev1, expectedRev1, TOLERANCE, "Half-decay reverse applies remaining, not raw leftover");

        uint256 balanceA = INITIAL_LIQUIDITY + STANDARD_SWAP - outRev1;
        uint256 balanceB = INITIAL_LIQUIDITY - outFirst + reverseIn;

        vm.warp(block.timestamp + DECAY_PERIOD / 2);

        // The original A→B resistance expires at t0 + period despite the intermediate B→A swap.
        uint256 expectedRev2 = (reverseIn * balanceA) / (balanceB + reverseIn);

        (, uint256 outRev2) = executeSwap(
            trader1, order, signature, address(tokenB), address(tokenA), reverseIn
        );
        assertApproxEqRel(
            outRev2,
            expectedRev2,
            TOLERANCE,
            "Opposite-direction swaps must not restart decay"
        );
    }

    function test_MEVSandwichProtection_SmallFrontRun() public {
        (ISwapVM.Order memory order, bytes memory signature) = createDecayOrder();
        uint256 mevInitialBalance = TokenMock(tokenA).balanceOf(mevBot);

        // MEV Bot front-runs with small A->B swap (50e18)
        (uint256 mevIn1, uint256 mevOut1) = executeSwap(
            mevBot,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            50e18 // small front-run
        );

        // Victim swaps A->B (same direction, no penalty, 200e18)
        (, uint256 victimOut) = executeSwap(
            trader1,
            order,
            signature,
            address(tokenA),
            address(tokenB),
            200e18
        );

        // Verify victim gets reasonable rate (no penalty for same direction)
        // After 50e18 swap strategy is: 1050:952.
        // After 200e18 swap strategy is: 1250:800
        uint256 expectedVictimOut = (uint256(200e18) * 870) / 1150;
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

    // Test 3: MEV Protection (Sandwich Attack)
    function test_MEVSandwichProtection_LargeFrontRun() public {
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

    function buildDecay(uint16 period) external pure {
        Decay.build(period);
    }

    function test_Decay_ZeroPeriod() public {
        vm.expectRevert(Decay.DecayPeriodMustBeNonZero.selector);
        this.buildDecay(0);
    }
}
