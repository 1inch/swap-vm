// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test, console } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwapStrictAdditive, XYCSwapStrictAdditiveArgsBuilder } from "../src/instructions/XYCSwapStrictAdditive.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { StrictAdditiveMath } from "../src/libs/StrictAdditiveMath.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { RoundingInvariants } from "./invariants/RoundingInvariants.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract XYCSwapStrictAdditiveTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    // Alpha scale constant (1e9 = 100%)
    uint256 constant ALPHA_SCALE = 1e9;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");

        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);
        tokenA.mint(taker, 1000000e18);
        tokenB.mint(taker, 1000000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _makeOrder(uint256 balanceA, uint256 balanceB, uint32 alpha) internal view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_xycSwapStrictAdditiveXD, XYCSwapStrictAdditiveArgsBuilder.build(alpha))
        );

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
            program: bytecode
        }));
    }

    function _signAndPack(ISwapVM.Order memory order, bool isExactIn, uint256 threshold) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        return abi.encodePacked(TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: taker,
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
        })));
    }

    // ========================================
    // BASIC SWAP TESTS
    // ========================================

    function test_XYCSwapStrictAdditive_BasicSwap_NoFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(ALPHA_SCALE); // 1.0 = no fee (standard x*y=k)

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 10e18;
        // With alpha=1.0, should behave like standard constant product
        uint256 expectedOut = (amountIn * poolB) / (poolA + amountIn);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        // Allow small difference due to fixed-point precision (18 decimals)
        assertApproxEqAbs(amountOut, expectedOut, 100, "Output should match x*y=k formula when alpha=1");
    }

    function test_XYCSwapStrictAdditive_BasicSwap_WithFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997 = ~0.3% fee

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 100e18;

        // Standard x*y=k output (without fee)
        uint256 noFeeOut = (amountIn * poolB) / (poolA + amountIn);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        // With fee reinvested, output should be less than no-fee output
        assertLt(amountOut, noFeeOut, "Output should be less than no-fee output");

        console.log("No fee output:", noFeeOut);
        console.log("With fee output:", amountOut);
        console.log("Fee retained in reserve:", noFeeOut - amountOut);
    }

    function test_XYCSwapStrictAdditive_BasicSwap_HighFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(950_000_000); // 0.95 = ~5% fee

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 100e18;

        // Standard x*y=k output (without fee)
        uint256 noFeeOut = (amountIn * poolB) / (poolA + amountIn);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        // With fee reinvested inside pricing, output should be less than no-fee
        // Note: The fee retained in reserve is (1 - (x/(x+dx))^alpha) vs (1 - x/(x+dx))
        // For alpha < 1, (x/(x+dx))^alpha > x/(x+dx), so output < noFeeOut
        assertLt(amountOut, noFeeOut, "Output should be less than no-fee output");

        // The fee effect: retained Y = noFeeOut - amountOut > 0
        uint256 feeRetained = noFeeOut - amountOut;
        assertGt(feeRetained, 0, "Fee should be positive");

        console.log("No fee output:", noFeeOut);
        console.log("With 5% fee output:", amountOut);
        console.log("Fee retained:", feeRetained);
    }

    // ========================================
    // STRICT ADDITIVITY TESTS (Split Invariance)
    // ========================================

    function test_XYCSwapStrictAdditive_SplitInvariance_TwoSwaps() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 totalAmount = 100e18;
        uint256 firstPart = 40e18;
        uint256 secondPart = 60e18;

        // Method 1: Single swap of total amount
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Method 2: Split swap (firstPart + secondPart)
        vm.revertTo(snapshot);
        vm.prank(taker);
        (, uint256 firstSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), firstPart, takerData);
        vm.prank(taker);
        (, uint256 secondSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), secondPart, takerData);

        uint256 splitSwapOut = firstSwapOut + secondSwapOut;

        console.log("Single swap output:", singleSwapOut);
        console.log("Split swap output (40+60):", splitSwapOut);
        console.log("First part output:", firstSwapOut);
        console.log("Second part output:", secondSwapOut);

        // Strict additivity: split swap should equal single swap
        // Allow small tolerance for floating-point precision
        assertApproxEqRel(splitSwapOut, singleSwapOut, 1e15, "Split swap should equal single swap (strict additivity)");
    }

    function test_XYCSwapStrictAdditive_SplitInvariance_PrecisionAnalysis() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 totalAmount = 100e18;
        uint256 firstPart = 40e18;
        uint256 secondPart = 60e18;

        // Method 1: Single swap of total amount
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Method 2: Split swap (firstPart + secondPart)
        vm.revertTo(snapshot);
        vm.prank(taker);
        (, uint256 firstSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), firstPart, takerData);
        vm.prank(taker);
        (, uint256 secondSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), secondPart, takerData);

        uint256 splitSwapOut = firstSwapOut + secondSwapOut;

        // Calculate precision loss details
        uint256 absDiff = singleSwapOut > splitSwapOut
            ? singleSwapOut - splitSwapOut
            : splitSwapOut - singleSwapOut;

        // Relative difference (in 1e18 scale, so 1e18 = 100%)
        uint256 relDiff = absDiff * 1e18 / singleSwapOut;

        console.log("\n========== PRECISION LOSS ANALYSIS (40+60 split) ==========");
        console.log("Single swap output (wei):     ", singleSwapOut);
        console.log("Split swap output (wei):      ", splitSwapOut);
        console.log("First part output (wei):      ", firstSwapOut);
        console.log("Second part output (wei):     ", secondSwapOut);
        console.log("------------------------------------------------------------");
        console.log("Absolute difference (wei):    ", absDiff);
        console.log("Relative difference (1e18=100%):", relDiff);
        console.log("Relative difference (ppm):    ", relDiff / 1e12); // parts per million
        console.log("Relative difference (ppb):    ", relDiff / 1e9);  // parts per billion
        console.log("------------------------------------------------------------");
        console.log("Single > Split?:              ", singleSwapOut > splitSwapOut ? "YES" : "NO");
        console.log("Tolerance used (1e15):        ", uint256(1e15));
        console.log("Within tolerance?:            ", relDiff <= 1e15 ? "YES" : "NO");
        console.log("============================================================\n");

        // Test with different split ratios
        _testSplitPrecision(order, takerData, totalAmount, 10e18, 90e18, "10+90");
        _testSplitPrecision(order, takerData, totalAmount, 50e18, 50e18, "50+50");
        _testSplitPrecision(order, takerData, totalAmount, 1e18, 99e18, "1+99");
        _testSplitPrecision(order, takerData, totalAmount, 99e18, 1e18, "99+1");

        // Test with more splits (3-way, 5-way, 10-way)
        console.log("\n========== MULTI-SPLIT PRECISION ==========");
        _testMultiSplitPrecision(order, takerData, totalAmount, 3, "3-way");
        _testMultiSplitPrecision(order, takerData, totalAmount, 5, "5-way");
        _testMultiSplitPrecision(order, takerData, totalAmount, 10, "10-way");
        _testMultiSplitPrecision(order, takerData, totalAmount, 20, "20-way");
        _testMultiSplitPrecision(order, takerData, totalAmount, 100, "100-way");
    }

    function _testMultiSplitPrecision(
        ISwapVM.Order memory order,
        bytes memory takerData,
        uint256 totalAmount,
        uint256 numSplits,
        string memory label
    ) internal {
        uint256 partAmount = totalAmount / numSplits;

        // Single swap
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Multi-split swap
        vm.revertTo(snapshot);
        uint256 splitSwapOut = 0;
        for (uint256 i = 0; i < numSplits; i++) {
            vm.prank(taker);
            (, uint256 swapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), partAmount, takerData);
            splitSwapOut += swapOut;
        }

        uint256 absDiff = singleSwapOut > splitSwapOut
            ? singleSwapOut - splitSwapOut
            : splitSwapOut - singleSwapOut;
        uint256 relDiff = absDiff * 1e18 / singleSwapOut;

        console.log(string.concat(label, " split - Abs diff (wei): "), absDiff, " Rel (ppb):", relDiff / 1e9);

        vm.revertTo(snapshot);
    }

    function _testSplitPrecision(
        ISwapVM.Order memory order,
        bytes memory takerData,
        uint256 totalAmount,
        uint256 firstPart,
        uint256 secondPart,
        string memory label
    ) internal {
        // Single swap
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Split swap
        vm.revertTo(snapshot);
        vm.prank(taker);
        (, uint256 firstSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), firstPart, takerData);
        vm.prank(taker);
        (, uint256 secondSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), secondPart, takerData);

        uint256 splitSwapOut = firstSwapOut + secondSwapOut;
        uint256 absDiff = singleSwapOut > splitSwapOut
            ? singleSwapOut - splitSwapOut
            : splitSwapOut - singleSwapOut;
        uint256 relDiff = absDiff * 1e18 / singleSwapOut;

        console.log(string.concat("Split ", label, " - Abs diff (wei): "), absDiff, " Rel diff (ppb):", relDiff / 1e9);

        vm.revertTo(snapshot);
    }

    function test_XYCSwapStrictAdditive_PrecisionAnalysis_DifferentFees() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 totalAmount = 100e18;

        console.log("\n========== PRECISION vs FEE LEVEL (10-way split) ==========");

        // Test different fee levels
        uint32[] memory alphas = new uint32[](6);
        alphas[0] = uint32(1e9);         // 0% fee (alpha=1.0)
        alphas[1] = uint32(999_000_000); // 0.1% fee
        alphas[2] = uint32(997_000_000); // 0.3% fee (Uniswap-like)
        alphas[3] = uint32(990_000_000); // 1% fee
        alphas[4] = uint32(950_000_000); // 5% fee
        alphas[5] = uint32(900_000_000); // 10% fee

        string[6] memory labels = ["0% fee  ", "0.1% fee", "0.3% fee", "1% fee  ", "5% fee  ", "10% fee "];

        for (uint256 i = 0; i < alphas.length; i++) {
            ISwapVM.Order memory order = _makeOrder(poolA, poolB, alphas[i]);
            bytes memory takerData = _signAndPack(order, true, 0);

            // Single swap
            uint256 snapshot = vm.snapshot();
            vm.prank(taker);
            (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

            // 10-way split
            vm.revertTo(snapshot);
            uint256 splitSwapOut = 0;
            uint256 partAmount = totalAmount / 10;
            for (uint256 j = 0; j < 10; j++) {
                vm.prank(taker);
                (, uint256 swapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), partAmount, takerData);
                splitSwapOut += swapOut;
            }

            uint256 absDiff = singleSwapOut > splitSwapOut
                ? singleSwapOut - splitSwapOut
                : splitSwapOut - singleSwapOut;

            console.log(string.concat(labels[i], " - Diff (wei):"), absDiff, "Single:", singleSwapOut / 1e15);

            vm.revertTo(snapshot);
        }
    }

    function test_XYCSwapStrictAdditive_PrecisionAnalysis_SmallAmounts() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000);

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        console.log("\n========== PRECISION vs SWAP SIZE (10-way split) ==========");

        // Test different swap sizes
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1e12;   // 0.000001 tokens
        amounts[1] = 1e15;   // 0.001 tokens
        amounts[2] = 1e18;   // 1 token
        amounts[3] = 100e18; // 100 tokens
        amounts[4] = 500e18; // 500 tokens (50% of pool)

        string[5] memory labels = ["0.000001", "0.001   ", "1       ", "100     ", "500     "];

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 totalAmount = amounts[i];

            // Single swap
            uint256 snapshot = vm.snapshot();
            vm.prank(taker);
            (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

            // 10-way split
            vm.revertTo(snapshot);
            uint256 splitSwapOut = 0;
            uint256 partAmount = totalAmount / 10;
            for (uint256 j = 0; j < 10; j++) {
                vm.prank(taker);
                (, uint256 swapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), partAmount, takerData);
                splitSwapOut += swapOut;
            }

            uint256 absDiff = singleSwapOut > splitSwapOut
                ? singleSwapOut - splitSwapOut
                : splitSwapOut - singleSwapOut;

            uint256 relDiffPpb = singleSwapOut > 0 ? (absDiff * 1e9 / singleSwapOut) : 0;

            console.log(string.concat(labels[i], " tokens - Diff (wei):"), absDiff, "Rel (ppb):", relDiffPpb);

            vm.revertTo(snapshot);
        }
    }

    function test_XYCSwapStrictAdditive_SplitInvariance_ManySwaps() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 totalAmount = 100e18;
        uint256 numSwaps = 10;
        uint256 partAmount = totalAmount / numSwaps;

        // Method 1: Single swap
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Method 2: Many small swaps
        vm.revertTo(snapshot);
        uint256 splitSwapOut = 0;
        for (uint256 i = 0; i < numSwaps; i++) {
            vm.prank(taker);
            (, uint256 swapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), partAmount, takerData);
            splitSwapOut += swapOut;
        }

        console.log("Single swap output:", singleSwapOut);
        console.log("10x split swap output:", splitSwapOut);

        // Strict additivity should hold
        assertApproxEqRel(splitSwapOut, singleSwapOut, 1e15, "10x split swap should equal single swap");
    }

    function test_XYCSwapStrictAdditive_SplitInvariance_CompareToStandardXYK() public {
        // This test demonstrates the difference between strict additive and standard Uniswap-style
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 totalAmount = 100e18;
        uint256 firstPart = 40e18;
        uint256 secondPart = 60e18;

        // Strict additive: single swap
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 singleSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmount, takerData);

        // Strict additive: split swap
        vm.revertTo(snapshot);
        vm.prank(taker);
        (, uint256 firstSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), firstPart, takerData);
        vm.prank(taker);
        (, uint256 secondSwapOut,) = swapVM.swap(order, address(tokenA), address(tokenB), secondPart, takerData);

        uint256 splitSwapOut = firstSwapOut + secondSwapOut;

        console.log("\n=== Strict Additive (x^alpha * y = K) ===");
        console.log("Single swap:", singleSwapOut);
        console.log("Split swap:", splitSwapOut);
        console.log("Difference:", singleSwapOut > splitSwapOut ? singleSwapOut - splitSwapOut : splitSwapOut - singleSwapOut);

        // The difference should be negligible (due to strict additivity)
        uint256 diff = singleSwapOut > splitSwapOut ? singleSwapOut - splitSwapOut : splitSwapOut - singleSwapOut;
        assertLt(diff, singleSwapOut / 1000, "Strict additive should have minimal split difference");
    }

    // ========================================
    // EXACTOUT TESTS
    // ========================================

    /// @notice ExactOut with "two curves" design
    /// @dev In the two curves design, ExactOut uses calcExactIn with swapped semantics
    /// This means ExactOut is NOT the mathematical inverse of ExactIn on the same curve
    /// Instead, it applies the power to balanceIn, treating amountOut as the "input" parameter
    function test_XYCSwapStrictAdditive_ExactOut_Basic() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

        uint256 amountOut = 10e18;

        vm.prank(taker);
        (uint256 amountIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), amountOut, takerData);

        console.log("\n=== ExactOut with Two Curves Design ===");
        console.log("Amount out requested:", amountOut);
        console.log("Amount in required:", amountIn);

        // With "two curves" design, ExactOut uses calcExactIn formula:
        // amountIn = balanceOut * (1 - (balanceIn / (balanceIn + amountOut))^α)
        // This is NOT the traditional inverse, but a different calculation
        uint256 expectedFromFormula = StrictAdditiveMath.calcExactIn(poolA, poolB, amountOut, alpha);
        console.log("Expected from formula:", expectedFromFormula);
        
        assertEq(amountIn, expectedFromFormula, "Should match calcExactIn formula");
        
        // Note: In this design, amountIn may be LESS than CP baseline because
        // the power is applied to balanceIn, not solved inversely
        uint256 cpAmountIn = amountOut * poolA / (poolB - amountOut);
        console.log("CP baseline:", cpAmountIn);
        console.log("Difference from CP:", cpAmountIn > amountIn ? cpAmountIn - amountIn : amountIn - cpAmountIn);
        console.log("================================\n");
    }

    function test_XYCSwapStrictAdditive_ExactOut_SplitInvariance() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

        uint256 totalAmountOut = 100e18;
        uint256 firstPart = 40e18;
        uint256 secondPart = 60e18;

        // Single swap
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (uint256 singleSwapIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmountOut, takerData);

        // Split swap
        vm.revertTo(snapshot);
        vm.prank(taker);
        (uint256 firstSwapIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), firstPart, takerData);
        vm.prank(taker);
        (uint256 secondSwapIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), secondPart, takerData);

        uint256 splitSwapIn = firstSwapIn + secondSwapIn;

        console.log("ExactOut - Single swap in:", singleSwapIn);
        console.log("ExactOut - Split swap in:", splitSwapIn);

        // Strict additivity for ExactOut
        assertApproxEqRel(splitSwapIn, singleSwapIn, 1e15, "ExactOut split should equal single swap");
    }

    /// @notice Comprehensive test for ExactOut strict additivity with multiple split ratios
    function test_XYCSwapStrictAdditive_ExactOut_StrictAdditivity_Comprehensive() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

        uint256 totalAmountOut = 100e18;

        console.log("\n================================================================================");
        console.log("          EXACTOUT STRICT ADDITIVITY ANALYSIS");
        console.log("================================================================================\n");

        // Test 1: Single swap baseline
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (uint256 singleSwapIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), totalAmountOut, takerData);
        console.log("Single swap (100 out) - Input required:", singleSwapIn);
        vm.revertTo(snapshot);

        // Test 2: 2-way split (40+60)
        vm.prank(taker);
        (uint256 in1,,) = swapVM.swap(order, address(tokenA), address(tokenB), 40e18, takerData);
        vm.prank(taker);
        (uint256 in2,,) = swapVM.swap(order, address(tokenA), address(tokenB), 60e18, takerData);
        uint256 split2Way = in1 + in2;
        uint256 diff2Way = split2Way > singleSwapIn ? split2Way - singleSwapIn : singleSwapIn - split2Way;
        console.log("2-way split (40+60) - Input required:", split2Way, "Diff:", diff2Way);
        vm.revertTo(snapshot);

        // Test 3: 5-way split (20+20+20+20+20)
        uint256 split5Way = 0;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(taker);
            (uint256 inPart,,) = swapVM.swap(order, address(tokenA), address(tokenB), 20e18, takerData);
            split5Way += inPart;
        }
        uint256 diff5Way = split5Way > singleSwapIn ? split5Way - singleSwapIn : singleSwapIn - split5Way;
        console.log("5-way split (5x20) - Input required:", split5Way, "Diff:", diff5Way);
        vm.revertTo(snapshot);

        // Test 4: 10-way split
        uint256 split10Way = 0;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(taker);
            (uint256 inPart,,) = swapVM.swap(order, address(tokenA), address(tokenB), 10e18, takerData);
            split10Way += inPart;
        }
        uint256 diff10Way = split10Way > singleSwapIn ? split10Way - singleSwapIn : singleSwapIn - split10Way;
        console.log("10-way split (10x10) - Input required:", split10Way, "Diff:", diff10Way);

        console.log("\n--------------------------------------------------------------------------------");
        console.log("STRICT ADDITIVITY VERIFICATION:");
        console.log("  2-way rel diff (ppb):", diff2Way * 1e9 / singleSwapIn);
        console.log("  5-way rel diff (ppb):", diff5Way * 1e9 / singleSwapIn);
        console.log("  10-way rel diff (ppb):", diff10Way * 1e9 / singleSwapIn);

        // All should be within tolerance
        assertApproxEqRel(split2Way, singleSwapIn, 1e15, "2-way split should equal single swap");
        assertApproxEqRel(split5Way, singleSwapIn, 1e15, "5-way split should equal single swap");
        assertApproxEqRel(split10Way, singleSwapIn, 1e15, "10-way split should equal single swap");

        console.log("  Result: STRICT ADDITIVITY HOLDS for ExactOut");
        console.log("================================================================================\n");
    }

    /// @notice Verify fee is reinvested for ExactOut direction
    function test_XYCSwapStrictAdditive_ExactOut_FeeReinvestment() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 amountOut = 100e18;

        console.log("\n================================================================================");
        console.log("          EXACTOUT FEE REINVESTMENT ANALYSIS");
        console.log("================================================================================\n");

        console.log("Pool: x = 1000e18, y = 1000e18, amountOut = 100e18\n");

        // Test different alpha values
        uint32[] memory alphas = new uint32[](5);
        alphas[0] = uint32(1e9);         // α=1.0 (no fee)
        alphas[1] = uint32(997_000_000); // α=0.997 (~0.3% fee)
        alphas[2] = uint32(990_000_000); // α=0.99 (~1% fee)
        alphas[3] = uint32(970_000_000); // α=0.97 (~3% fee)
        alphas[4] = uint32(950_000_000); // α=0.95 (~5% fee)

        string[5] memory feeLabels = ["0% (alpha=1.0)  ", "0.3% (alpha=0.997)", "1% (alpha=0.99) ", "3% (alpha=0.97) ", "5% (alpha=0.95) "];

        // Traditional CP baseline: amountIn = amountOut * balanceIn / (balanceOut - amountOut)
        uint256 cpBaseline = amountOut * poolA / (poolB - amountOut);
        console.log("Traditional x*y=k baseline input:", cpBaseline);
        console.log("");

        for (uint256 i = 0; i < alphas.length; i++) {
            uint256 snapshot = vm.snapshot();

            ISwapVM.Order memory order = _makeOrder(poolA, poolB, alphas[i]);
            bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

            vm.prank(taker);
            (uint256 actualIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), amountOut, takerData);

            // Fee reinvested = extra input required compared to baseline
            // When α < 1, user pays MORE input for same output (fee goes to pool)
            uint256 feeReinvested = actualIn > cpBaseline ? actualIn - cpBaseline : 0;

            // Calculate K growth
            uint256 newPoolA = poolA + actualIn;
            uint256 newPoolB = poolB - amountOut;
            uint256 oldK = (poolA / 1e9) * (poolB / 1e9);
            uint256 newK = (newPoolA / 1e9) * (newPoolB / 1e9);
            uint256 kGrowthBps = newK > oldK ? ((newK - oldK) * 10000) / oldK : 0;

            console.log(feeLabels[i]);
            console.log("  Input required:  ", actualIn);
            console.log("  Fee reinvested:  ", feeReinvested);
            console.log("  K growth (bps):  ", kGrowthBps);

            vm.revertTo(snapshot);
        }

        console.log("\n--------------------------------------------------------------------------------");
        console.log("INTERPRETATION:");
        console.log("  - With fee (alpha < 1), user pays MORE input for same output");
        console.log("  - The extra input goes to the pool, increasing reserves");
        console.log("  - This causes K to grow, benefiting LPs");
        console.log("  - Fee reinvestment works in BOTH ExactIn and ExactOut directions");
        console.log("================================================================================\n");
    }

    /// @notice Verify ExactIn and ExactOut behavior with "two curves" design
    /// @dev In two curves design, ExactOut is NOT the inverse of ExactIn!
    /// Both use calcExactIn but with different meanings for the parameters
    function test_XYCSwapStrictAdditive_ExactInOut_TwoCurves() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);

        console.log("\n================================================================================");
        console.log("          EXACTIN vs EXACTOUT: TWO CURVES DESIGN");
        console.log("================================================================================\n");

        console.log("In 'two curves' design:");
        console.log("  - ExactIn:  amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountIn))^alpha)");
        console.log("  - ExactOut: amountIn = balanceOut * (1 - (balanceIn / (balanceIn + amountOut))^alpha)");
        console.log("  Note: ExactOut uses the SAME formula but with amountOut in place of amountIn!");
        console.log("");

        // ExactIn: 100 tokens in -> how much out?
        bytes memory takerDataExactIn = _signAndPack(order, true, 0);
        uint256 snapshot = vm.snapshot();
        vm.prank(taker);
        (, uint256 outFromExactIn,) = swapVM.swap(order, address(tokenA), address(tokenB), 100e18, takerDataExactIn);
        console.log("ExactIn: 100e18 A in -> B out:", outFromExactIn);
        vm.revertTo(snapshot);

        // ExactOut: request same amount out -> how much in?
        bytes memory takerDataExactOut = _signAndPack(order, false, 0);
        vm.prank(taker);
        (uint256 inFromExactOut,,) = swapVM.swap(order, address(tokenA), address(tokenB), outFromExactIn, takerDataExactOut);
        console.log("ExactOut: request B:", outFromExactIn);
        console.log("  -> need A:", inFromExactOut);

        console.log("");
        console.log("KEY DIFFERENCE FROM TRADITIONAL AMM:");
        console.log("  In traditional AMM, ExactOut would require ~100e18 A to get the same B");
        console.log("  In two curves design, the formulas are different, so results differ");
        
        // Calculate what traditional inverse would be
        // Traditional: amountIn = balanceIn * ((balanceOut / (balanceOut - amountOut))^(1/α) - 1)
        uint256 traditionalInverse = StrictAdditiveMath.calcExactOut(poolA, poolB, outFromExactIn, alpha);
        console.log("");
        console.log("Traditional inverse would need:", traditionalInverse, "A");
        console.log("Two curves design needs:       ", inFromExactOut, "A");
        console.log("Difference:                    ", traditionalInverse > inFromExactOut ? traditionalInverse - inFromExactOut : inFromExactOut - traditionalInverse);

        // Verify the two curves formula is applied correctly
        uint256 expectedTwoCurves = StrictAdditiveMath.calcExactIn(poolA, poolB, outFromExactIn, alpha);
        assertEq(inFromExactOut, expectedTwoCurves, "ExactOut should use calcExactIn formula");

        console.log("\n================================================================================\n");
    }

    // ========================================
    // TWO CURVES ROUND-TRIP TESTS
    // ========================================
    // The strict additive model uses TWO CURVES:
    //   - A→B direction: balanceA^α * balanceB = K₁  (power on input token A)
    //   - B→A direction: balanceB^α * balanceA = K₂  (power on input token B)
    // This means the power is ALWAYS on the INPUT token (balanceIn).

    /// @notice Test round-trip A→B→A using ExactIn both ways
    /// @dev Demonstrates "two curves" behavior where each direction uses different invariant
    function test_XYCSwapStrictAdditive_TwoCurves_RoundTrip_ExactIn() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerDataExactIn = _signAndPack(order, true, 0);

        console.log("\n================================================================================");
        console.log("          TWO CURVES ROUND-TRIP TEST (ExactIn both directions)");
        console.log("================================================================================\n");

        console.log("Pool: A = 1000e18, B = 1000e18, alpha = 0.997");
        console.log("Curve A->B: A^alpha * B = K1");
        console.log("Curve B->A: B^alpha * A = K2");
        console.log("");

        uint256 initialAmountA = 100e18;
        console.log("Starting with:", initialAmountA, "of token A");

        // Step 1: Swap A → B (ExactIn)
        // Uses curve: (A + dA)^α * (B - dB) = A^α * B
        vm.prank(taker);
        (, uint256 receivedB,) = swapVM.swap(order, address(tokenA), address(tokenB), initialAmountA, takerDataExactIn);
        console.log("\nStep 1: A -> B (ExactIn)");
        console.log("  Input A: ", initialAmountA);
        console.log("  Output B:", receivedB);

        // Step 2: Swap B → A (ExactIn)
        // Uses curve: (B + dB)^α * (A - dA) = B^α * A  (DIFFERENT curve!)
        vm.prank(taker);
        (, uint256 finalAmountA,) = swapVM.swap(order, address(tokenB), address(tokenA), receivedB, takerDataExactIn);
        console.log("\nStep 2: B -> A (ExactIn)");
        console.log("  Input B: ", receivedB);
        console.log("  Output A:", finalAmountA);

        // Calculate loss
        uint256 loss = initialAmountA - finalAmountA;
        uint256 lossBps = loss * 10000 / initialAmountA;
        console.log("\n--------------------------------------------------------------------------------");
        console.log("ROUND-TRIP RESULTS:");
        console.log("  Initial A:  ", initialAmountA);
        console.log("  Final A:    ", finalAmountA);
        console.log("  Loss:       ", loss);
        console.log("  Loss (bps): ", lossBps);

        // With 0.3% fee on each leg, expect ~0.6% total loss
        // Actually it's less due to the "two curves" effect
        console.log("\nExpected: ~0.6% loss from two 0.3% fee legs");
        console.log("The 'two curves' design means each direction has its own invariant");
        console.log("================================================================================\n");

        // Verify no profit from round-trip
        assertLt(finalAmountA, initialAmountA, "Should lose value on round-trip due to fees");
        // Loss should be roughly 2 * fee rate
        assertGt(lossBps, 40, "Loss should be at least 0.4%");
        assertLt(lossBps, 80, "Loss should be at most 0.8%");
    }

    /// @notice Test round-trip using ExactIn forward and ExactOut backward
    function test_XYCSwapStrictAdditive_TwoCurves_RoundTrip_Mixed() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerDataExactIn = _signAndPack(order, true, 0);
        bytes memory takerDataExactOut = _signAndPack(order, false, 0);

        console.log("\n================================================================================");
        console.log("          TWO CURVES ROUND-TRIP TEST (Mixed ExactIn/ExactOut)");
        console.log("================================================================================\n");

        uint256 initialAmountA = 100e18;
        console.log("Starting with:", initialAmountA, "of token A");

        // Step 1: Swap A → B (ExactIn)
        vm.prank(taker);
        (, uint256 receivedB,) = swapVM.swap(order, address(tokenA), address(tokenB), initialAmountA, takerDataExactIn);
        console.log("\nStep 1: A -> B (ExactIn)");
        console.log("  Input A: ", initialAmountA);
        console.log("  Output B:", receivedB);

        // Step 2: Swap B → A (ExactOut) - request exactly initialAmountA back
        vm.prank(taker);
        (uint256 requiredB,,) = swapVM.swap(order, address(tokenB), address(tokenA), initialAmountA, takerDataExactOut);
        console.log("\nStep 2: B -> A (ExactOut, requesting initial amount back)");
        console.log("  Requested A:", initialAmountA);
        console.log("  Required B: ", requiredB);

        console.log("\n--------------------------------------------------------------------------------");
        console.log("ANALYSIS:");
        console.log("  B received from A->B:", receivedB);
        console.log("  B required for A<-B: ", requiredB);
        
        if (requiredB > receivedB) {
            console.log("  Shortfall:          ", requiredB - receivedB);
            console.log("  Result: CANNOT get back original amount - fees consumed too much");
        } else {
            console.log("  Excess B:           ", receivedB - requiredB);
            console.log("  Result: CAN get back original (but shouldn't happen with fees!)");
        }
        
        // With fees, should require MORE B than we received
        assertGt(requiredB, receivedB, "Round-trip should require more input than received (fees)");
        console.log("================================================================================\n");
    }

    /// @notice Verify the two curves produce different K values
    function test_XYCSwapStrictAdditive_TwoCurves_DifferentInvariants() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        console.log("\n================================================================================");
        console.log("          TWO CURVES: DIFFERENT INVARIANTS");
        console.log("================================================================================\n");

        // Calculate K for curve 1: A^α * B
        // K1 = (1000e18)^0.997 * 1000e18
        uint256 K1_ratio = StrictAdditiveMath.powRatio(poolA, 1e18, alpha);
        uint256 K1 = K1_ratio * poolB / 1e18;

        // Calculate K for curve 2: A * B^α
        // K2 = 1000e18 * (1000e18)^0.997
        uint256 K2_ratio = StrictAdditiveMath.powRatio(poolB, 1e18, alpha);
        uint256 K2 = poolA * K2_ratio / 1e18;

        console.log("Pool: A = 1000e18, B = 1000e18, alpha = 0.997");
        console.log("");
        console.log("Curve 1 (A->B): K1 = A^alpha * B");
        console.log("  A^alpha (scaled):", K1_ratio);
        console.log("  K1 =", K1);
        console.log("");
        console.log("Curve 2 (B->A): K2 = A * B^alpha");
        console.log("  B^alpha (scaled):", K2_ratio);
        console.log("  K2 =", K2);
        console.log("");

        // For symmetric pool, K1 should equal K2
        console.log("For symmetric pool (A == B), K1 should equal K2:");
        console.log("  K1 == K2?", K1 == K2 ? "YES" : "NO");
        assertEq(K1, K2, "Symmetric pool should have same K for both curves");

        console.log("\n--------------------------------------------------------------------------------");
        console.log("KEY INSIGHT:");
        console.log("  - When going A->B, we use A^alpha * B = K (power on INPUT token)");
        console.log("  - When going B->A, we use B^alpha * A = K (power on INPUT token)");
        console.log("  - The power is ALWAYS on balanceIn, which swaps based on direction");
        console.log("  - This creates 'two curves' behavior for asymmetric pools");
        console.log("================================================================================\n");
    }

    /// @notice Test asymmetric pool where two curves differ
    function test_XYCSwapStrictAdditive_TwoCurves_AsymmetricPool() public {
        // Asymmetric pool: A = 2000, B = 500
        uint256 poolA = 2000e18;
        uint256 poolB = 500e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerDataExactIn = _signAndPack(order, true, 0);

        console.log("\n================================================================================");
        console.log("          TWO CURVES: ASYMMETRIC POOL");
        console.log("================================================================================\n");

        console.log("Pool: A = 2000e18, B = 500e18, alpha = 0.997");
        console.log("Price ratio: 1 A = 0.25 B (approximately)");
        console.log("");

        // Swap A → B
        uint256 amountA = 100e18;
        vm.prank(taker);
        (, uint256 receivedB,) = swapVM.swap(order, address(tokenA), address(tokenB), amountA, takerDataExactIn);

        // Swap B → A with same value
        uint256 amountB = 25e18; // Equivalent value
        vm.prank(taker);
        (, uint256 receivedA,) = swapVM.swap(order, address(tokenB), address(tokenA), amountB, takerDataExactIn);

        console.log("Swap 100 A -> B:");
        console.log("  Input A: ", amountA);
        console.log("  Output B:", receivedB);
        console.log("  Implied price: 1 A =", receivedB * 1e18 / amountA, "e-18 B");
        console.log("");
        console.log("Swap 25 B -> A:");
        console.log("  Input B: ", amountB);
        console.log("  Output A:", receivedA);
        console.log("  Implied price: 1 B =", receivedA * 1e18 / amountB, "e-18 A");

        console.log("\n--------------------------------------------------------------------------------");
        console.log("In asymmetric pools, the two curves create DIFFERENT effective prices");
        console.log("because the power (alpha) is applied to different reserve sizes.");
        console.log("================================================================================\n");
    }

    /// @notice Multiple round-trips to show fee accumulation
    function test_XYCSwapStrictAdditive_TwoCurves_MultipleRoundTrips() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerDataExactIn = _signAndPack(order, true, 0);

        console.log("\n================================================================================");
        console.log("          MULTIPLE ROUND-TRIPS: FEE ACCUMULATION");
        console.log("================================================================================\n");

        uint256 currentA = 100e18;
        console.log("Starting amount A:", currentA);
        console.log("");
        console.log("Round | After A->B (B) | After B->A (A) | Cumulative Loss");
        console.log("--------------------------------------------------------------");

        uint256 initialA = currentA;

        for (uint256 i = 1; i <= 5; i++) {
            // A → B
            vm.prank(taker);
            (, uint256 gotB,) = swapVM.swap(order, address(tokenA), address(tokenB), currentA, takerDataExactIn);
            
            // B → A
            vm.prank(taker);
            (, currentA,) = swapVM.swap(order, address(tokenB), address(tokenA), gotB, takerDataExactIn);
            
            uint256 loss = initialA - currentA;
            uint256 lossBps = loss * 10000 / initialA;
            
            console.log("Round", i);
            console.log("  After A->B (B):", gotB);
            console.log("  After B->A (A):", currentA);
            console.log("  Cumulative loss (bps):", lossBps);
        }

        console.log("--------------------------------------------------------------");
        console.log("\nFinal amount A:", currentA);
        console.log("Total loss:    ", initialA - currentA);
        console.log("Total loss %:  ", (initialA - currentA) * 100 / initialA, "%");
        console.log("");
        console.log("Each round-trip loses ~0.6% due to fees on both legs.");
        console.log("Fees are reinvested into pool reserves (K grows).");
        console.log("================================================================================\n");

        // After 5 round-trips, should have lost ~3% (5 * 0.6%)
        uint256 finalLossBps = (initialA - currentA) * 10000 / initialA;
        assertGt(finalLossBps, 250, "Should lose at least 2.5% after 5 round-trips");
        assertLt(finalLossBps, 350, "Should lose at most 3.5% after 5 round-trips");
    }

    // ========================================
    // NUMERICAL EXAMPLES FROM PAPER
    // ========================================

    function test_XYCSwapStrictAdditive_PaperExample() public {
        // From the paper: x=1000, y=1000, Δx=100, α=0.997
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 100e18;

        // Paper says:
        // y' = 1000 * (1000/1100)^0.997 ≈ 909.3508831104
        // Δy = 1000 - 909.3508831104 ≈ 90.6491168896

        // Constant product baseline:
        // ycp = 1000 * 1000 / 1100 = 909.0909090909
        // Δycp = 90.9090909091
        uint256 expectedCPOut = (amountIn * poolB) / (poolA + amountIn);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        console.log("\n=== Paper Example Verification ===");
        console.log("Amount in:", amountIn / 1e18, "e18");
        console.log("Expected CP output:", expectedCPOut / 1e18, "e18");
        console.log("Actual output:", amountOut / 1e18, "e18");
        console.log("Fee retained (y' - ycp):", (expectedCPOut - amountOut) / 1e12, "e-6");

        // Output should be less than constant product (fee is reinvested)
        assertLt(amountOut, expectedCPOut, "Output should be less than CP baseline");

        // Fee retained should be positive
        assertGt(expectedCPOut - amountOut, 0, "Fee should be positive");
    }

    function test_XYCSwapStrictAdditive_PaperExample_SplitInvariance() public {
        // Verify split invariance: 40 + 60 = 100
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 snapshot = vm.snapshot();

        // Single swap of 100
        vm.prank(taker);
        (, uint256 singleOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 100e18, takerData);

        vm.revertTo(snapshot);

        // First trade: 40
        vm.prank(taker);
        (, uint256 firstOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 40e18, takerData);

        // Second trade: 60
        vm.prank(taker);
        (, uint256 secondOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 60e18, takerData);

        console.log("\n=== Paper Split Invariance Check (40+60) ===");
        console.log("Single swap (100):", singleOut);
        console.log("First swap (40):", firstOut);
        console.log("Second swap (60):", secondOut);
        console.log("Combined (40+60):", firstOut + secondOut);

        uint256 diff = singleOut > (firstOut + secondOut)
            ? singleOut - (firstOut + secondOut)
            : (firstOut + secondOut) - singleOut;
        console.log("Difference:", diff);

        // Should match within precision
        assertApproxEqRel(firstOut + secondOut, singleOut, 1e15, "Split invariance violated");
    }

    // ========================================
    // ROUNDING INVARIANT TESTS
    // ========================================

    /// @notice Comprehensive rounding invariants test using the library
    /// @dev Uses configurable amounts for Balancer-style power math that requires larger minimums
    function test_XYCSwapStrictAdditive_RoundingInvariants_Library() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        // Run comprehensive rounding invariant tests with configurable amounts
        // Strict additive uses Balancer-style power calculations that require larger
        // minimum amounts (1e12 = 0.000001 tokens) to produce non-zero outputs
        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwapForInvariant,
            1e12,  // minAtomicAmount: 0.000001 tokens (power math precision floor)
            1      // toleranceBps: 0.01% for floating-point precision in power calculations
        );
    }

    /// @dev Helper for RoundingInvariants library
    function _executeSwapForInvariant(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = _swapVM.swap(order, tokenIn, tokenOut, amount, takerData);
    }

    // ========================================
    // EDGE CASE TESTS
    // ========================================

    function test_XYCSwapStrictAdditive_SmallAmounts() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000);

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        // Very small swap
        uint256 amountIn = 1e12; // 0.000001 tokens

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        assertGt(amountOut, 0, "Should produce non-zero output for small amounts");
    }

    function test_XYCSwapStrictAdditive_LargeAmounts() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000);

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        // Large swap (50% of pool)
        uint256 amountIn = 500e18;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        // Should get significant output
        assertGt(amountOut, 300e18, "Should produce significant output for large swap");
        assertLt(amountOut, poolB, "Output should be less than pool balance");
    }

    function test_XYCSwapStrictAdditive_AsymmetricPool() public {
        uint256 poolA = 100e18;
        uint256 poolB = 10000e18;
        uint32 alpha = uint32(997_000_000);

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 10e18;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        // Should get more tokenB due to asymmetric pool
        assertGt(amountOut, amountIn, "Should get more output from asymmetric pool");
    }

    // ========================================
    // GAS COMPARISON: STRICT ADDITIVE vs TRADITIONAL XY=K
    // ========================================

    function test_XYCSwapStrictAdditive_GasComparison_vsTraditionalXYK() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 amountIn = 100e18;

        console.log("\n========== GAS COMPARISON: Strict Additive vs Traditional XY=K ==========");

        // ---- Traditional XY=K (alpha = 1.0, no fee) ----
        {
            ISwapVM.Order memory orderTraditional = _makeOrder(poolA, poolB, uint32(ALPHA_SCALE)); // alpha=1.0
            bytes memory takerDataTraditional = _signAndPack(orderTraditional, true, 0);

            uint256 gasBefore = gasleft();
            vm.prank(taker);
            (, uint256 outTraditional,) = swapVM.swap(orderTraditional, address(tokenA), address(tokenB), amountIn, takerDataTraditional);
            uint256 gasTraditionalAlpha1 = gasBefore - gasleft();

            console.log("Strict Additive (alpha=1.0, no fee):");
            console.log("  Gas used:", gasTraditionalAlpha1);
            console.log("  Output:", outTraditional);
        }

        // Reset balances
        setUp();

        // ---- Strict Additive with 0.3% fee (alpha = 0.997) ----
        {
            ISwapVM.Order memory orderStrictAdditive = _makeOrder(poolA, poolB, uint32(997_000_000)); // alpha=0.997
            bytes memory takerDataStrictAdditive = _signAndPack(orderStrictAdditive, true, 0);

            uint256 gasBefore = gasleft();
            vm.prank(taker);
            (, uint256 outStrictAdditive,) = swapVM.swap(orderStrictAdditive, address(tokenA), address(tokenB), amountIn, takerDataStrictAdditive);
            uint256 gasStrictAdditive = gasBefore - gasleft();

            console.log("\nStrict Additive (alpha=0.997, 0.3% fee):");
            console.log("  Gas used:", gasStrictAdditive);
            console.log("  Output:", outStrictAdditive);
        }

        // Reset balances
        setUp();

        // ---- Strict Additive with 5% fee (alpha = 0.95) ----
        {
            ISwapVM.Order memory orderHighFee = _makeOrder(poolA, poolB, uint32(950_000_000)); // alpha=0.95
            bytes memory takerDataHighFee = _signAndPack(orderHighFee, true, 0);

            uint256 gasBefore = gasleft();
            vm.prank(taker);
            (, uint256 outHighFee,) = swapVM.swap(orderHighFee, address(tokenA), address(tokenB), amountIn, takerDataHighFee);
            uint256 gasHighFee = gasBefore - gasleft();

            console.log("\nStrict Additive (alpha=0.95, 5% fee):");
            console.log("  Gas used:", gasHighFee);
            console.log("  Output:", outHighFee);
        }

        console.log("\n==========================================================================\n");
    }

    function test_XYCSwapStrictAdditive_GasComparison_MathOnly() public {
        // Direct math comparison without the swap VM overhead
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 1000e18;
        uint256 amountIn = 100e18;
        uint256 alpha = 997_000_000; // 0.997

        console.log("\n========== PURE MATH GAS COMPARISON ==========");

        // Traditional XY=K formula: amountOut = (amountIn * balanceOut) / (balanceIn + amountIn)
        uint256 gasBefore = gasleft();
        uint256 traditionalOut = (amountIn * balanceOut) / (balanceIn + amountIn);
        uint256 gasTraditional = gasBefore - gasleft();

        console.log("Traditional XY=K (x*y=k):");
        console.log("  Gas (pure math):", gasTraditional);
        console.log("  Output:", traditionalOut);

        // Strict Additive formula via StrictAdditiveMath (Balancer-style optimized)
        gasBefore = gasleft();
        uint256 strictAdditiveOut = StrictAdditiveMath.calcExactIn(balanceIn, balanceOut, amountIn, alpha);
        uint256 gasStrictAdditive = gasBefore - gasleft();

        console.log("\nStrict Additive (x^alpha * y = k):");
        console.log("  Gas (pure math):", gasStrictAdditive);
        console.log("  Output:", strictAdditiveOut);

        console.log("\n-------- SUMMARY --------");
        console.log("Traditional XY=K gas:", gasTraditional);
        console.log("Strict Additive gas: ", gasStrictAdditive);
        console.log("Gas overhead:        ", gasStrictAdditive - gasTraditional);
        console.log("Fee retained:        ", traditionalOut - strictAdditiveOut);
        console.log("================================================\n");
    }

    function test_XYCSwapStrictAdditive_GasComparison_DetailedBenchmark() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 1000e18;
        uint256 alpha = 997_000_000; // 0.997

        console.log("\n========== STRICT ADDITIVE GAS BENCHMARK ==========");

        // Test different swap sizes
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1e15;    // 0.001 tokens
        amounts[1] = 1e18;    // 1 token
        amounts[2] = 10e18;   // 10 tokens
        amounts[3] = 100e18;  // 100 tokens
        amounts[4] = 500e18;  // 500 tokens

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amountIn = amounts[i];

            uint256 gasBefore = gasleft();
            uint256 amountOut = StrictAdditiveMath.calcExactIn(balanceIn, balanceOut, amountIn, alpha);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("ExactIn", amountIn / 1e15, "e15 -> Gas:", gasUsed);
            console.log("  Output:", amountOut);
        }

        // Test ExactOut
        console.log("\n-------- ExactOut Benchmark --------");
        uint256 amountOutTarget = 50e18;

        uint256 gasBeforeExact = gasleft();
        uint256 amountInNeeded = StrictAdditiveMath.calcExactOut(balanceIn, balanceOut, amountOutTarget, alpha);
        uint256 gasExactOut = gasBeforeExact - gasleft();

        console.log("ExactOut 50e18 -> Gas:", gasExactOut, "Input:", amountInNeeded);

        // Round-trip verification
        console.log("\n-------- Round-trip Verification --------");
        uint256 roundTripOut = StrictAdditiveMath.calcExactIn(balanceIn, balanceOut, amountInNeeded, alpha);
        uint256 roundTripDiff = roundTripOut > amountOutTarget ? roundTripOut - amountOutTarget : amountOutTarget - roundTripOut;

        console.log("Target: 50e18, Got:", roundTripOut);
        console.log("Precision error (wei):", roundTripDiff);

        console.log("====================================================\n");
    }

    function test_XYCSwapStrictAdditive_GasComparison_DifferentAlphas() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 1000e18;
        uint256 amountIn = 100e18;

        console.log("\n========== GAS vs ALPHA VALUE ==========");

        uint256[] memory alphas = new uint256[](5);
        alphas[0] = 1e9;          // 1.0 (no fee)
        alphas[1] = 999_000_000;  // 0.999
        alphas[2] = 997_000_000;  // 0.997
        alphas[3] = 950_000_000;  // 0.95
        alphas[4] = 500_000_000;  // 0.5

        for (uint256 i = 0; i < alphas.length; i++) {
            uint256 alpha = alphas[i];

            uint256 gasBefore = gasleft();
            uint256 amountOut = StrictAdditiveMath.calcExactIn(balanceIn, balanceOut, amountIn, alpha);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Alpha:", alpha / 1e6, "e-3 -> Gas:", gasUsed);
            console.log("  Output:", amountOut);
        }

        console.log("=========================================\n");
    }

    function test_XYCSwapStrictAdditive_GasComparison_ExactOut() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 amountOut = 50e18;

        console.log("\n========== GAS COMPARISON: ExactOut ==========");

        // ---- Strict Additive with no fee (alpha = 1.0) ----
        {
            ISwapVM.Order memory order = _makeOrder(poolA, poolB, uint32(ALPHA_SCALE));
            bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

            uint256 gasBefore = gasleft();
            vm.prank(taker);
            (uint256 inNoFee,,) = swapVM.swap(order, address(tokenA), address(tokenB), amountOut, takerData);
            uint256 gasNoFee = gasBefore - gasleft();

            console.log("Strict Additive ExactOut (alpha=1.0):");
            console.log("  Gas used:", gasNoFee);
            console.log("  Input required:", inNoFee);
        }

        setUp();

        // ---- Strict Additive with 0.3% fee (alpha = 0.997) ----
        {
            ISwapVM.Order memory order = _makeOrder(poolA, poolB, uint32(997_000_000));
            bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

            uint256 gasBefore = gasleft();
            vm.prank(taker);
            (uint256 inWithFee,,) = swapVM.swap(order, address(tokenA), address(tokenB), amountOut, takerData);
            uint256 gasWithFee = gasBefore - gasleft();

            console.log("\nStrict Additive ExactOut (alpha=0.997):");
            console.log("  Gas used:", gasWithFee);
            console.log("  Input required:", inWithFee);
        }

        console.log("===============================================\n");
    }

    // ========================================
    // FEE REINVESTMENT DEMONSTRATION
    // ========================================

    /// @notice Demonstrates how much fee is reinvested in the pool
    /// @dev Key insight: In strict additive model, the fee is NOT collected externally.
    /// Instead, it's "reinvested" by giving the taker less output, which effectively
    /// increases the pool's reserves (and thus its K value).
    function test_XYCSwapStrictAdditive_FeeReinvestmentAnalysis() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 amountIn = 100e18;

        console.log("\n================================================================================");
        console.log("          FEE REINVESTMENT ANALYSIS: Strict Additive vs Traditional");
        console.log("================================================================================\n");

        console.log("Initial pool state:");
        console.log("  Reserve X (tokenA):", poolA / 1e18, "tokens");
        console.log("  Reserve Y (tokenB):", poolB / 1e18, "tokens");
        console.log("  Initial K (x * y):", (poolA / 1e18) * (poolB / 1e18));
        console.log("  Swap amount in:", amountIn / 1e18, "tokenA");
        console.log("");

        // Test different fee levels
        uint32[] memory alphas = new uint32[](5);
        alphas[0] = uint32(1e9);         // α=1.0 (0% fee - equivalent to x*y=k)
        alphas[1] = uint32(997_000_000); // α=0.997 (~0.3% fee like Uniswap)
        alphas[2] = uint32(990_000_000); // α=0.99 (~1% fee)
        alphas[3] = uint32(970_000_000); // α=0.97 (~3% fee)
        alphas[4] = uint32(950_000_000); // α=0.95 (~5% fee)

        string[5] memory feeLabels = ["0% (alpha=1.0)  ", "0.3% (alpha=0.997)", "1% (alpha=0.99) ", "3% (alpha=0.97) ", "5% (alpha=0.95) "];

        console.log("--------------------------------------------------------------------------------");
        console.log("Fee Level           | Output (e18)  | Fee Reinvested | K Growth (bps)");
        console.log("--------------------------------------------------------------------------------");

        // Calculate traditional x*y=k output for comparison baseline
        uint256 traditionalOutput = (amountIn * poolB) / (poolA + amountIn);

        for (uint256 i = 0; i < alphas.length; i++) {
            uint256 snapshot = vm.snapshot();

            ISwapVM.Order memory order = _makeOrder(poolA, poolB, alphas[i]);
            bytes memory takerData = _signAndPack(order, true, 0);

            vm.prank(taker);
            (, uint256 actualOutput,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

            // Calculate new pool state after swap
            uint256 newPoolA = poolA + amountIn;        // Full input credited to pool
            uint256 newPoolB = poolB - actualOutput;    // Actual output removed

            // Calculate invariants
            // Traditional K = x * y
            uint256 oldK = (poolA / 1e9) * (poolB / 1e9);    // scaled down to avoid overflow
            uint256 newK = (newPoolA / 1e9) * (newPoolB / 1e9);

            // Fee reinvested = difference between traditional output and actual output
            // Note: when alpha=1.0 (no fee), actual ~= traditional, handle potential underflow
            uint256 feeReinvested = actualOutput < traditionalOutput ? traditionalOutput - actualOutput : 0;

            // K growth percentage (scaled by 1e4 for precision)
            uint256 kGrowthBps = newK > oldK ? ((newK - oldK) * 10000) / oldK : 0;

            console.log(feeLabels[i]);
            console.log("  Output:         ", actualOutput);
            console.log("  Fee reinvested: ", feeReinvested);
            console.log("  K growth (bps): ", kGrowthBps);

            vm.revertTo(snapshot);
        }

        console.log("--------------------------------------------------------------------------------");
        console.log("");
        console.log("Interpretation:");
        console.log("- 'Fee Reinvested' = output you would get with x*y=k MINUS actual output");
        console.log("- This 'fee' stays in the pool, increasing reserves and K");
        console.log("- Higher fee (lower alpha) = more reinvestment = larger K growth");
        console.log("- At alpha=1.0, strict additive degenerates to standard x*y=k (no fee)");
        console.log("================================================================================\n");
    }

    /// @notice Shows pool reserve changes before and after multiple swaps
    function test_XYCSwapStrictAdditive_PoolReserveGrowth() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997 = ~0.3% fee

        console.log("\n================================================================================");
        console.log("               POOL RESERVE GROWTH OVER MULTIPLE SWAPS");
        console.log("                    (alpha = 0.997 = ~0.3% fee)");
        console.log("================================================================================\n");

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        console.log("Trade # | Output (e18) | Reserve X | Reserve Y | Fee Reinvested");
        console.log("-------------------------------------------------------------------");

        uint256 currentPoolA = poolA;
        uint256 currentPoolB = poolB;
        uint256 swapAmount = 50e18; // 50 tokens per swap

        uint256 totalFeeReinvested = 0;

        for (uint256 i = 1; i <= 10; i++) {
            // Calculate what traditional x*y=k would output
            uint256 traditionalOut = (swapAmount * currentPoolB) / (currentPoolA + swapAmount);

            // Execute the strict additive swap
            vm.prank(taker);
            (, uint256 actualOut,) = swapVM.swap(order, address(tokenA), address(tokenB), swapAmount, takerData);

            // Update virtual pool reserves
            currentPoolA += swapAmount;
            currentPoolB -= actualOut;

            // Fee reinvested this trade
            uint256 feeThisTrade = traditionalOut - actualOut;
            totalFeeReinvested += feeThisTrade;

            console.log("Trade", i);
            console.log("  Output:         ", actualOut);
            console.log("  Reserve X:      ", currentPoolA);
            console.log("  Reserve Y:      ", currentPoolB);
            console.log("  Fee reinvested: ", feeThisTrade);
        }

        console.log("-------------------------------------------------------------------");
        console.log("\nSummary after 10 swaps of 50 tokens each:");
        uint256 initialK = (poolA / 1e9) * (poolB / 1e9);
        uint256 finalK = (currentPoolA / 1e9) * (currentPoolB / 1e9);
        console.log("  Initial K (scaled):     ", initialK);
        console.log("  Final K (scaled):       ", finalK);
        console.log("  K Growth (scaled):      ", finalK - initialK);
        console.log("  Total Fee Reinvested:   ", totalFeeReinvested);
        console.log("  Total Volume:           ", swapAmount * 10);
        console.log("  Fee % of volume (bps):  ", totalFeeReinvested * 10000 / (swapAmount * 10));
        console.log("================================================================================\n");
    }

    /// @notice Compares exact fee calculation between traditional and strict additive
    function test_XYCSwapStrictAdditive_ExactFeeCalculation() public pure {
        uint256 x = 1000e18;  // Reserve X
        uint256 y = 1000e18;  // Reserve Y
        uint256 dx = 100e18;  // Amount in
        uint256 alpha = 997_000_000; // 0.997

        console.log("\n================================================================================");
        console.log("                    EXACT FEE CALCULATION BREAKDOWN");
        console.log("================================================================================\n");

        console.log("Pool: x = 1000e18, y = 1000e18, alpha = 0.997, dx = 100e18\n");

        // Traditional constant product: dy = y * dx / (x + dx)
        // Equivalent to: y' = x * y / (x + dx), so dy = y - y'
        uint256 traditionalDy = (dx * y) / (x + dx);
        uint256 newYTraditional = y - traditionalDy;

        console.log("TRADITIONAL x*y=k:");
        console.log("  Formula: dy = y * dx / (x + dx)");
        console.log("  dy (output):   ", traditionalDy);
        console.log("  New y reserve: ", newYTraditional);
        console.log("  K before:      ", (x / 1e9) * (y / 1e9));
        console.log("  K after:       ", ((x + dx) / 1e9) * (newYTraditional / 1e9));
        console.log("");

        // Strict additive: dy = y * (1 - (x / (x + dx))^alpha)
        uint256 strictAdditiveDy = StrictAdditiveMath.calcExactIn(x, y, dx, alpha);
        uint256 newYStrictAdditive = y - strictAdditiveDy;

        console.log("STRICT ADDITIVE x^alpha * y = K:");
        console.log("  Formula: dy = y * (1 - (x / (x + dx))^alpha)");
        console.log("  dy (output):   ", strictAdditiveDy);
        console.log("  New y reserve: ", newYStrictAdditive);

        // Calculate new K for strict additive (using simple x*y for comparison)
        uint256 newKSimple = ((x + dx) / 1e9) * (newYStrictAdditive / 1e9);
        console.log("  K (x*y) after: ", newKSimple);
        console.log("");

        // Fee reinvested
        uint256 feeReinvested = traditionalDy - strictAdditiveDy;
        uint256 feePercentBps = feeReinvested * 10000 / dx;

        console.log("FEE REINVESTED IN POOL:");
        console.log("  Traditional output - Strict additive output:");
        console.log("    Fee reinvested:    ", feeReinvested);
        console.log("    Fee in bps:        ", feePercentBps);
        console.log("");

        // Show where the fee "goes"
        console.log("WHERE DOES THE FEE GO?");
        console.log("  - In traditional AMM with 0.3% fee: fee is taken from input BEFORE swap");
        console.log("    (e.g., effective input = 99.7 tokens, fee = 0.3 tokens collected separately)");
        console.log("");
        console.log("  - In strict additive: full 100 tokens go to reserve, but pricing formula");
        console.log("    gives LESS output, effectively 'reinvesting' the fee into pool liquidity");
        console.log("    (reserve X increases by full dx, reserve Y decreases by less than x*y=k)");
        console.log("");
        console.log("  Result: Pool's K grows, benefiting LPs through increased reserves");
        console.log("================================================================================\n");
    }

    /// @notice Shows fee reinvestment for different swap sizes
    function test_XYCSwapStrictAdditive_FeeBySwapSize() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        console.log("\n================================================================================");
        console.log("              FEE REINVESTED BY SWAP SIZE (alpha = 0.997)");
        console.log("================================================================================\n");

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        console.log("Testing swap sizes from 0.1% to 200% of pool...\n");

        uint256[] memory swapSizes = new uint256[](8);
        swapSizes[0] = 1e18;    // 0.1%
        swapSizes[1] = 10e18;   // 1%
        swapSizes[2] = 50e18;   // 5%
        swapSizes[3] = 100e18;  // 10%
        swapSizes[4] = 200e18;  // 20%
        swapSizes[5] = 500e18;  // 50%
        swapSizes[6] = 1000e18; // 100%
        swapSizes[7] = 2000e18; // 200%

        for (uint256 i = 0; i < swapSizes.length; i++) {
            uint256 snapshot = vm.snapshot();
            uint256 swapAmount = swapSizes[i];

            // Traditional output
            uint256 traditionalOut = (swapAmount * poolB) / (poolA + swapAmount);

            // Strict additive output
            vm.prank(taker);
            (, uint256 actualOut,) = swapVM.swap(order, address(tokenA), address(tokenB), swapAmount, takerData);

            uint256 feeReinvested = traditionalOut - actualOut;
            uint256 feePercentBps = swapAmount > 0 ? feeReinvested * 10000 / swapAmount : 0;
            uint256 poolPercent = swapAmount * 100 / poolA;

            console.log("Swap size (% of pool):", poolPercent);
            console.log("  Amount in:          ", swapAmount);
            console.log("  Traditional output: ", traditionalOut);
            console.log("  Actual output:      ", actualOut);
            console.log("  Fee reinvested:     ", feeReinvested);
            console.log("  Fee (bps of input): ", feePercentBps);
            console.log("");

            vm.revertTo(snapshot);
        }

        console.log("-------------------------------------------------------------------");
        console.log("\nObservation: Effective fee % is roughly constant across swap sizes (~30 bps)");
        console.log("This is the 'fee reinvestment' property - fee scales proportionally with trade size");
        console.log("================================================================================\n");
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = _swapVM.swap(order, tokenIn, tokenOut, amount, takerData);
    }
}
