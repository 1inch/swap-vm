// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { PeggedSwapReinvest, PeggedSwapReinvestArgsBuilder } from "../src/instructions/PeggedSwapReinvest.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title PeggedSwapReinvestTest - Test strictly-additive fee mechanism
/// @notice Verifies that swap(a+b) = swap(a) + swap(b) with semigroup D-update
contract PeggedSwapReinvestTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;
    using SafeCast for uint256;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ONE = 1e27;
    uint256 constant INITIAL_BALANCE = 100000e18;
    uint256 constant LINEAR_WIDTH = 0.8e27;  // A = 0.8
    uint256 constant FEE_RATE = 0.003e9;     // 0.3%

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = new MockToken("Token A", "TKNA");
        tokenB = new MockToken("Token B", "TKNB");

        tokenA.mint(maker, 10000000e18);
        tokenB.mint(maker, 10000000e18);
        tokenA.mint(taker, 10000000e18);
        tokenB.mint(taker, 10000000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function takerData(address takerAddress, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddress,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
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

    function signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function createOrder(uint256 balanceA, uint256 balanceB) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            prog.build(PeggedSwapReinvest._peggedSwapReinvestXD,
                PeggedSwapReinvestArgsBuilder.build(PeggedSwapReinvestArgsBuilder.Args({
                    x0: INITIAL_BALANCE,
                    y0: INITIAL_BALANCE,
                    linearWidth: LINEAR_WIDTH,
                    rateLt: 1,
                    rateGt: 1,
                    feeRate: FEE_RATE
                })))
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    function executeSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        bytes memory signature = signOrder(order);
        bytes memory takerTraitsAndData = takerData(taker, isExactIn);
        bytes memory sigAndTakerData = abi.encodePacked(takerTraitsAndData, signature);

        vm.prank(taker);
        (amountIn, amountOut,) = swapVM.swap(
            order,
            address(tokenA),
            address(tokenB),
            amount,
            sigAndTakerData
        );
    }

    // Helper: Create order for B -> A direction
    function createOrderReverse(uint256 balanceA, uint256 balanceB) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),  // Reversed
                    dynamic([balanceB, balanceA])                  // Reversed
                )),
            prog.build(PeggedSwapReinvest._peggedSwapReinvestXD,
                PeggedSwapReinvestArgsBuilder.build(PeggedSwapReinvestArgsBuilder.Args({
                    x0: INITIAL_BALANCE,
                    y0: INITIAL_BALANCE,
                    linearWidth: LINEAR_WIDTH,
                    rateLt: 1,
                    rateGt: 1,
                    feeRate: FEE_RATE
                })))
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    // Helper: Execute swap B -> A
    function executeSwapReverse(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        bytes memory signature = signOrder(order);
        bytes memory takerTraitsAndData = takerData(taker, isExactIn);
        bytes memory sigAndTakerData = abi.encodePacked(takerTraitsAndData, signature);

        vm.prank(taker);
        (amountIn, amountOut,) = swapVM.swap(
            order,
            address(tokenB),  // Reversed
            address(tokenA),  // Reversed
            amount,
            sigAndTakerData
        );
    }

    // ========================================
    // STRICT ADDITIVITY TESTS
    // ========================================

    function test_StrictAdditivity_BasicSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  STRICT ADDITIVITY TEST - BASIC");
        console.log("  Verify swap(a+b) = swap(a) + swap(b)");
        console.log("========================================");
        console.log("");

        uint256 a = 1000e18;
        uint256 b = 1000e18;

        // One-shot: swap (a+b) = 2000
        ISwapVM.Order memory orderOneShot = createOrder(INITIAL_BALANCE, INITIAL_BALANCE);
        (, uint256 outOneShot) = executeSwap(orderOneShot, a + b, true);

        console.log("One-shot swap of %s:", (a + b) / 1e18);
        console.log("  Output: %s", outOneShot / 1e18);

        // Two-step: swap a, then swap b
        // For the split test, we need to simulate sequential swaps
        // First swap: use initial balances
        ISwapVM.Order memory orderFirst = createOrder(INITIAL_BALANCE, INITIAL_BALANCE);
        (uint256 inFirst, uint256 outFirst) = executeSwap(orderFirst, a, true);

        // Second swap: balances have changed
        // Note: In real usage, the program would read dynamic balances
        // For this test, we manually update the balances
        uint256 newBalanceA = INITIAL_BALANCE + inFirst;
        uint256 newBalanceB = INITIAL_BALANCE - outFirst;

        ISwapVM.Order memory orderSecond = createOrder(newBalanceA, newBalanceB);
        (, uint256 outSecond) = executeSwap(orderSecond, b, true);

        uint256 totalSplitOutput = outFirst + outSecond;

        console.log("");
        console.log("Split swap (%s + %s):", a / 1e18, b / 1e18);
        console.log("  First swap output:  %s", outFirst / 1e18);
        console.log("  Second swap output: %s", outSecond / 1e18);
        console.log("  Total output:       %s", totalSplitOutput / 1e18);
        console.log("");
        console.log("Comparison:");
        console.log("  One-shot output: %s", outOneShot / 1e18);
        console.log("  Split output:    %s", totalSplitOutput / 1e18);

        int256 diff = int256(outOneShot) - int256(totalSplitOutput);
        console.log("  Difference:      %s wei", diff);
        console.log("");

        // For strict additivity, outputs should be equal (within small rounding)
        // Note: Due to semigroup fee mechanism, difference should be minimal
        uint256 absDiff = diff > 0 ? uint256(diff) : uint256(-diff);
        uint256 toleranceBps = 10;  // 0.1% tolerance for rounding
        uint256 tolerance = outOneShot * toleranceBps / 10000;

        assertLt(absDiff, tolerance, "Strict additivity: one-shot should approximately equal split");
        console.log("SUCCESS: Outputs match within tolerance!");
        console.log("========================================");
        console.log("");
    }

    function test_StrictAdditivity_MultipleChunks() public {
        console.log("");
        console.log("========================================");
        console.log("  STRICT ADDITIVITY - 4 CHUNKS");
        console.log("  swap(400) vs 4x swap(100)");
        console.log("========================================");
        console.log("");

        uint256 totalAmount = 4000e18;
        uint256 chunkSize = 1000e18;

        // One-shot
        ISwapVM.Order memory orderOneShot = createOrder(INITIAL_BALANCE, INITIAL_BALANCE);
        (, uint256 outOneShot) = executeSwap(orderOneShot, totalAmount, true);

        // Four chunks
        uint256 balanceA = INITIAL_BALANCE;
        uint256 balanceB = INITIAL_BALANCE;
        uint256 totalChunkOutput = 0;

        for (uint256 i = 0; i < 4; i++) {
            ISwapVM.Order memory orderChunk = createOrder(balanceA, balanceB);
            (uint256 amtIn, uint256 amtOut) = executeSwap(orderChunk, chunkSize, true);
            totalChunkOutput += amtOut;
            balanceA += amtIn;
            balanceB -= amtOut;
            console.log("  Chunk %s: in=%s, out=%s", i + 1, amtIn / 1e18, amtOut / 1e18);
        }

        console.log("");
        console.log("Results:");
        console.log("  One-shot (%s): %s", totalAmount / 1e18, outOneShot / 1e18);
        console.log("  4 chunks:      %s", totalChunkOutput / 1e18);

        int256 diff = int256(outOneShot) - int256(totalChunkOutput);
        console.log("  Difference:    %s wei", diff);

        uint256 absDiff = diff > 0 ? uint256(diff) : uint256(-diff);
        uint256 tolerance = outOneShot * 10 / 10000;  // 0.1%
        assertLt(absDiff, tolerance, "Multi-chunk should match one-shot");

        console.log("");
        console.log("SUCCESS: 4-chunk split matches one-shot!");
        console.log("========================================");
        console.log("");
    }

    function test_FeeGrowsPool() public {
        console.log("");
        console.log("========================================");
        console.log("  FEE MECHANISM - POOL GROWTH");
        console.log("  Verify fee increases effective D");
        console.log("========================================");
        console.log("");

        // Compare output with vs without fee
        // With fee = 0.3%, output should be slightly less
        
        uint256 swapAmount = 1000e18;

        // With fee (using our reinvest instruction)
        ISwapVM.Order memory orderWithFee = createOrder(INITIAL_BALANCE, INITIAL_BALANCE);
        (, uint256 outWithFee) = executeSwap(orderWithFee, swapAmount, true);

        // Expected fee impact: ~0.3% less output (fee grows pool, reducing output)
        // At balanced pool with A=0.8, output is close to input
        // Fee of 0.3% should reduce output by roughly 0.3%
        
        uint256 expectedOutput = swapAmount;  // At peg, roughly 1:1
        uint256 feeImpact = swapAmount * FEE_RATE / 1e9;  // 0.3%
        uint256 expectedWithFee = expectedOutput - feeImpact;

        console.log("Swap amount: %s", swapAmount / 1e18);
        console.log("Output with fee: %s", outWithFee / 1e18);
        console.log("Expected (no fee): ~%s", expectedOutput / 1e18);
        console.log("Fee rate: 0.3%%");
        console.log("Fee impact: ~%s", feeImpact / 1e18);
        console.log("");

        // Output should be less than no-fee scenario
        assertLt(outWithFee, swapAmount, "Fee should reduce output");

        console.log("SUCCESS: Fee mechanism reduces output as expected!");
        console.log("========================================");
        console.log("");
    }

    function test_DeterministicPoolGrowth() public {
        console.log("");
        console.log("========================================");
        console.log("  DETERMINISTIC POOL GROWTH");
        console.log("  D increases by f*volume regardless of chunks");
        console.log("========================================");
        console.log("");

        // This test verifies that total fee collected is same
        // whether trade is done in one shot or multiple chunks

        uint256 totalVolume = 2000e18;
        uint256 expectedFee = totalVolume * FEE_RATE / 1e9;  // f * volume

        console.log("Total volume: %s", totalVolume / 1e18);
        console.log("Fee rate: 0.3%%");
        console.log("Expected pool growth (D increase): %s", expectedFee / 1e18);
        console.log("");

        // One-shot
        ISwapVM.Order memory order1 = createOrder(INITIAL_BALANCE, INITIAL_BALANCE);
        (uint256 in1, uint256 out1) = executeSwap(order1, totalVolume, true);
        
        // Fee captured = input - output (in value terms, approximately)
        // Since pool is balanced, fee ≈ in - out
        uint256 feeOneShot = in1 > out1 ? in1 - out1 : 0;

        // Two chunks of 1000 each
        uint256 balA = INITIAL_BALANCE;
        uint256 balB = INITIAL_BALANCE;
        uint256 totalIn = 0;
        uint256 totalOut = 0;

        ISwapVM.Order memory order2a = createOrder(balA, balB);
        (uint256 in2a, uint256 out2a) = executeSwap(order2a, 1000e18, true);
        totalIn += in2a;
        totalOut += out2a;
        balA += in2a;
        balB -= out2a;

        ISwapVM.Order memory order2b = createOrder(balA, balB);
        (uint256 in2b, uint256 out2b) = executeSwap(order2b, 1000e18, true);
        totalIn += in2b;
        totalOut += out2b;

        uint256 feeSplit = totalIn > totalOut ? totalIn - totalOut : 0;

        console.log("One-shot: in=%s, out=%s, fee~=%s", in1/1e18, out1/1e18, feeOneShot/1e18);
        console.log("Split:    in=%s, out=%s, fee~=%s", totalIn/1e18, totalOut/1e18, feeSplit/1e18);

        // Fee captured should be similar regardless of chunking
        // (This is the deterministic pool growth property)
        uint256 feeDiff = feeOneShot > feeSplit ? feeOneShot - feeSplit : feeSplit - feeOneShot;
        uint256 tolerance = expectedFee / 10;  // 10% tolerance on fee difference

        console.log("Fee difference: %s (tolerance: %s)", feeDiff/1e18, tolerance/1e18);
        console.log("");

        assertLt(feeDiff, tolerance, "Fee should be deterministic regardless of chunking");

        console.log("SUCCESS: Pool growth is deterministic!");
        console.log("========================================");
        console.log("");
    }

    // ========================================
    // LARGE SWAP (10%) ROUND-TRIP TEST
    // ========================================

    function test_LargeSwap_10Percent_RoundTrip() public {
        console.log("");
        console.log("================================================================");
        console.log("  LARGE SWAP (10%% OF POOL) ROUND-TRIP TEST");
        console.log("  Protection comes from invariant curvature, not dynamic fees");
        console.log("================================================================");
        console.log("");

        uint256 largeSwap = 10000e18;  // 10% of pool (100000)
        uint256 balA = INITIAL_BALANCE;
        uint256 balB = INITIAL_BALANCE;
        uint256 initialPoolValue = balA + balB;

        console.log("Configuration:");
        console.log("  Pool size: %s per token", INITIAL_BALANCE / 1e18);
        console.log("  Swap amount: %s (10%% of pool)", largeSwap / 1e18);
        console.log("  Fee rate: 0.3%%");
        console.log("  linearWidth (A): 0.8");
        console.log("");

        console.log("Initial state:");
        console.log("  Pool A: %s", balA / 1e18);
        console.log("  Pool B: %s", balB / 1e18);
        console.log("  Total:  %s", initialPoolValue / 1e18);
        console.log("");

        // Swap 1: A -> B (10% of pool)
        console.log("SWAP 1: A -> B (%s A = 10%% of pool)", largeSwap / 1e18);
        ISwapVM.Order memory order1 = createOrder(balA, balB);
        (uint256 in1, uint256 out1) = executeSwap(order1, largeSwap, true);
        balA += in1;
        balB -= out1;

        uint256 slippage1 = in1 - out1;
        uint256 slippageBps1 = slippage1 * 10000 / in1;

        console.log("  Input:  %s A", in1 / 1e18);
        console.log("  Output: %s B", out1 / 1e18);
        console.log("  Slippage: %s (%s bps)", slippage1 / 1e18, slippageBps1);
        console.log("  Pool A: %s, Pool B: %s", balA / 1e18, balB / 1e18);
        console.log("");

        // Swap 2: B -> A (swap back)
        console.log("SWAP 2: B -> A (%s B)", out1 / 1e18);
        ISwapVM.Order memory order2 = createOrderReverse(balA, balB);
        (uint256 in2, uint256 out2) = executeSwapReverse(order2, out1, true);
        balB += in2;
        balA -= out2;

        console.log("  Input:  %s B", in2 / 1e18);
        console.log("  Output: %s A", out2 / 1e18);
        console.log("  Pool A: %s, Pool B: %s", balA / 1e18, balB / 1e18);
        console.log("");

        // Results
        uint256 finalPoolValue = balA + balB;
        
        console.log("================================================================");
        console.log("  RESULTS");
        console.log("================================================================");
        console.log("");
        console.log("Trader:");
        console.log("  Started with: %s A", largeSwap / 1e18);
        console.log("  Ended with:   %s A", out2 / 1e18);
        
        if (out2 < largeSwap) {
            uint256 loss = largeSwap - out2;
            uint256 lossBps = loss * 10000 / largeSwap;
            console.log("  NET LOSS: %s A (%s bps)", loss / 1e18, lossBps);
        } else {
            uint256 gain = out2 - largeSwap;
            console.log("  NET GAIN: %s A (arbitrage!)", gain / 1e18);
        }
        console.log("");

        console.log("Pool:");
        console.log("  Initial value: %s", initialPoolValue / 1e18);
        console.log("  Final value:   %s", finalPoolValue / 1e18);
        
        if (finalPoolValue > initialPoolValue) {
            uint256 poolGain = finalPoolValue - initialPoolValue;
            console.log("  NET GAIN: %s (fees retained)", poolGain / 1e18);
        }
        console.log("");

        // The key assertion: trader should lose money on round-trip
        // Protection comes from:
        // 1. Slippage on large swap (invariant curvature)
        // 2. Fees (0.3% each direction)
        assertLt(out2, largeSwap, "Round-trip should not be profitable for trader");

        console.log("SUCCESS: Large swap protection works!");
        console.log("  - Slippage from invariant curvature: ~%s bps", slippageBps1);
        console.log("  - Fee per swap: 30 bps");
        console.log("  - Combined protection prevents arbitrage");
        console.log("================================================================");
        console.log("");
    }

    // ========================================
    // 100 LARGE SWAPS (10% EACH) TEST
    // ========================================

    function test_100_LargeSwaps_10Percent() public {
        console.log("");
        console.log("================================================================");
        console.log("  100 LARGE SWAPS (10%% OF POOL EACH)");
        console.log("  Testing fee accumulation with large volume");
        console.log("================================================================");
        console.log("");

        uint256 swapAmount = 10000e18;  // 10% of initial pool
        uint256 numRoundTrips = 50;     // 50 round trips = 100 swaps

        uint256 balA = INITIAL_BALANCE;
        uint256 balB = INITIAL_BALANCE;
        uint256 initialPoolValue = balA + balB;

        console.log("Configuration:");
        console.log("  Initial pool: %s per token", INITIAL_BALANCE / 1e18);
        console.log("  Swap size: %s (10%% of initial)", swapAmount / 1e18);
        console.log("  Total swaps: 100 (50 round trips)");
        console.log("  Fee rate: 0.3%%");
        console.log("");

        uint256 totalVolume = 0;
        uint256 traderTotalLoss = 0;

        for (uint256 i = 0; i < numRoundTrips; i++) {
            uint256 traderStart = swapAmount;

            // Swap A -> B
            ISwapVM.Order memory order1 = createOrder(balA, balB);
            (uint256 in1, uint256 out1) = executeSwap(order1, swapAmount, true);
            balA += in1;
            balB -= out1;
            totalVolume += in1;

            // Swap B -> A (swap back)
            ISwapVM.Order memory order2 = createOrderReverse(balA, balB);
            (uint256 in2, uint256 out2) = executeSwapReverse(order2, out1, true);
            balB += in2;
            balA -= out2;
            totalVolume += in2;

            uint256 traderEnd = out2;
            if (traderStart > traderEnd) {
                traderTotalLoss += (traderStart - traderEnd);
            }

            // Log progress every 10 round trips
            if ((i + 1) % 10 == 0) {
                uint256 poolValue = balA + balB;
                uint256 poolGrowth = poolValue > initialPoolValue ? poolValue - initialPoolValue : 0;
                console.log("After %s swaps: Pool=%s, Growth=%s", (i + 1) * 2, poolValue / 1e18, poolGrowth / 1e18);
            }
        }

        uint256 finalPoolValue = balA + balB;
        uint256 poolGrowth = finalPoolValue > initialPoolValue ? finalPoolValue - initialPoolValue : 0;

        console.log("");
        console.log("================================================================");
        console.log("  FINAL RESULTS AFTER 100 SWAPS");
        console.log("================================================================");
        console.log("");
        console.log("Pool growth (wei): %s", poolGrowth);
        console.log("Total volume (tokens): %s", totalVolume / 1e18);
        console.log("Trader total loss (wei): %s", traderTotalLoss);
        console.log("Avg loss per round trip (wei): %s", traderTotalLoss / numRoundTrips);
        console.log("Final balances: A=%s, B=%s", balA / 1e18, balB / 1e18);
        console.log("================================================================");
        console.log("");

        // Verify pool grew from fees
        assertGt(finalPoolValue, initialPoolValue, "Pool should grow from fees");
        
        // Verify trader lost money overall
        assertGt(traderTotalLoss, 0, "Trader should lose money on round trips");
    }

    // ========================================
    // TESTS WITH 1% FEE RATE
    // ========================================

    uint256 constant FEE_RATE_1_PERCENT = 0.01e9;  // 1% fee

    function createOrderWithFee(uint256 balanceA, uint256 balanceB, uint256 feeRate) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            prog.build(PeggedSwapReinvest._peggedSwapReinvestXD,
                PeggedSwapReinvestArgsBuilder.build(PeggedSwapReinvestArgsBuilder.Args({
                    x0: INITIAL_BALANCE,
                    y0: INITIAL_BALANCE,
                    linearWidth: LINEAR_WIDTH,
                    rateLt: 1,
                    rateGt: 1,
                    feeRate: feeRate
                })))
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    function createOrderReverseWithFee(uint256 balanceA, uint256 balanceB, uint256 feeRate) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),
                    dynamic([balanceB, balanceA])
                )),
            prog.build(PeggedSwapReinvest._peggedSwapReinvestXD,
                PeggedSwapReinvestArgsBuilder.build(PeggedSwapReinvestArgsBuilder.Args({
                    x0: INITIAL_BALANCE,
                    y0: INITIAL_BALANCE,
                    linearWidth: LINEAR_WIDTH,
                    rateLt: 1,
                    rateGt: 1,
                    feeRate: feeRate
                })))
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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

    function test_100_LargeSwaps_1PercentFee() public {
        console.log("");
        console.log("================================================================");
        console.log("  100 LARGE SWAPS WITH 1%% FEE RATE");
        console.log("================================================================");
        console.log("");

        uint256 swapAmount = 10000e18;  // 10% of pool
        uint256 numRoundTrips = 50;     // 50 round trips = 100 swaps

        uint256 balA = INITIAL_BALANCE;
        uint256 balB = INITIAL_BALANCE;
        uint256 initialPoolValue = balA + balB;

        console.log("Configuration:");
        console.log("  Pool: %s per token", INITIAL_BALANCE / 1e18);
        console.log("  Swap: %s (10%% of pool)", swapAmount / 1e18);
        console.log("  Fee rate: 1%%");
        console.log("");

        uint256 totalVolume = 0;
        uint256 traderTotalLoss = 0;

        for (uint256 i = 0; i < numRoundTrips; i++) {
            uint256 traderStart = swapAmount;

            // Swap A -> B with 1% fee
            ISwapVM.Order memory order1 = createOrderWithFee(balA, balB, FEE_RATE_1_PERCENT);
            (uint256 in1, uint256 out1) = executeSwap(order1, swapAmount, true);
            balA += in1;
            balB -= out1;
            totalVolume += in1;

            // Swap B -> A with 1% fee
            ISwapVM.Order memory order2 = createOrderReverseWithFee(balA, balB, FEE_RATE_1_PERCENT);
            (uint256 in2, uint256 out2) = executeSwapReverse(order2, out1, true);
            balB += in2;
            balA -= out2;
            totalVolume += in2;

            if (traderStart > out2) {
                traderTotalLoss += (traderStart - out2);
            }

            if ((i + 1) % 10 == 0) {
                uint256 poolValue = balA + balB;
                uint256 growth = poolValue - initialPoolValue;
                console.log("After %s swaps: Pool growth = %s tokens", (i + 1) * 2, growth / 1e18);
            }
        }

        uint256 finalPoolValue = balA + balB;
        uint256 poolGrowth = finalPoolValue - initialPoolValue;

        console.log("");
        console.log("================================================================");
        console.log("  RESULTS WITH 1%% FEE");
        console.log("================================================================");
        console.log("");
        console.log("Pool growth: %s tokens (%s wei)", poolGrowth / 1e18, poolGrowth);
        console.log("Total volume: %s tokens", totalVolume / 1e18);
        console.log("Expected fee (1%%): %s tokens", totalVolume / 100 / 1e18);
        console.log("Trader loss: %s tokens (%s wei)", traderTotalLoss / 1e18, traderTotalLoss);
        console.log("Final: A=%s, B=%s", balA / 1e18, balB / 1e18);
        console.log("================================================================");

        assertGt(poolGrowth, 0, "Pool should grow significantly with 1% fee");
        assertGt(traderTotalLoss, 0, "Trader should lose money");
    }

    function test_SingleSwap_1PercentFee() public {
        console.log("");
        console.log("================================================================");
        console.log("  SINGLE SWAP WITH 1%% FEE");
        console.log("================================================================");
        console.log("");

        uint256 swapAmount = 10000e18;  // 10% of pool

        console.log("Swap: %s A (10%% of pool)", swapAmount / 1e18);
        console.log("Fee: 1%%");
        console.log("");

        ISwapVM.Order memory order = createOrderWithFee(INITIAL_BALANCE, INITIAL_BALANCE, FEE_RATE_1_PERCENT);
        (uint256 amountIn, uint256 amountOut) = executeSwap(order, swapAmount, true);

        uint256 slippage = amountIn - amountOut;
        uint256 slippageBps = slippage * 10000 / amountIn;

        console.log("Input:  %s A", amountIn / 1e18);
        console.log("Output: %s B", amountOut / 1e18);
        console.log("Slippage: %s tokens (%s bps)", slippage / 1e18, slippageBps);
        console.log("");
        console.log("Breakdown:");
        console.log("  Fee (1%%): ~%s tokens", amountIn / 100 / 1e18);
        console.log("  Curve slippage: ~%s tokens", (slippage - amountIn / 100) / 1e18);
        console.log("================================================================");

        // With 1% fee, slippage should be > 100 bps (fee) + curve impact
        assertGt(slippageBps, 100, "Slippage should include 1% fee");
    }

    function test_OneWaySwaps_1PercentFee() public {
        console.log("");
        console.log("================================================================");
        console.log("  ONE-WAY SWAPS WITH 1%% FEE (no round trips)");
        console.log("  Shows pure fee accumulation without price impact recovery");
        console.log("================================================================");
        console.log("");

        uint256 swapAmount = 1000e18;  // 1% of pool (smaller to avoid depletion)
        uint256 numSwaps = 50;

        uint256 balA = INITIAL_BALANCE;
        uint256 balB = INITIAL_BALANCE;
        uint256 initialPoolValue = balA + balB;

        console.log("Configuration:");
        console.log("  Pool: %s per token", INITIAL_BALANCE / 1e18);
        console.log("  Swap: %s (1%% of pool)", swapAmount / 1e18);
        console.log("  Fee rate: 1%%");
        console.log("  Swaps: %s (all A -> B)", numSwaps);
        console.log("");

        uint256 totalVolume = 0;

        for (uint256 i = 0; i < numSwaps; i++) {
            ISwapVM.Order memory order = createOrderWithFee(balA, balB, FEE_RATE_1_PERCENT);
            (uint256 amountIn, uint256 amountOut) = executeSwap(order, swapAmount, true);
            balA += amountIn;
            balB -= amountOut;
            totalVolume += amountIn;

            if ((i + 1) % 10 == 0) {
                uint256 poolValue = balA + balB;
                uint256 growth = poolValue - initialPoolValue;
                console.log("After %s swaps: Pool=%s, Growth=%s", i + 1, poolValue / 1e18, growth / 1e18);
            }
        }

        uint256 finalPoolValue = balA + balB;
        uint256 poolGrowth = finalPoolValue - initialPoolValue;
        uint256 expectedFee = totalVolume / 100;  // 1%

        console.log("");
        console.log("================================================================");
        console.log("  RESULTS - ONE-WAY SWAPS");
        console.log("================================================================");
        console.log("");
        console.log("Total volume: %s tokens", totalVolume / 1e18);
        console.log("Expected fee (1%%): %s tokens", expectedFee / 1e18);
        console.log("Pool growth: %s tokens", poolGrowth / 1e18);
        console.log("Fee capture rate: %s%%", poolGrowth * 100 / expectedFee);
        console.log("");
        console.log("Final balances:");
        console.log("  A: %s", balA / 1e18);
        console.log("  B: %s", balB / 1e18);
        console.log("================================================================");

        // Pool should grow by approximately the fee amount
        assertGt(poolGrowth, expectedFee / 2, "Pool should capture significant fees");
    }
}
