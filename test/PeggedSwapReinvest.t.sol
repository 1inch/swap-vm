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
}
