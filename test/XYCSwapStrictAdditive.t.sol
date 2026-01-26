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

        // Allow 1 wei difference due to precision
        assertApproxEqAbs(amountOut, expectedOut, 1, "Output should match x*y=k formula when alpha=1");
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

    function test_XYCSwapStrictAdditive_ExactOut_Basic() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, false, 0); // ExactOut

        uint256 amountOut = 10e18;

        vm.prank(taker);
        (uint256 amountIn,,) = swapVM.swap(order, address(tokenA), address(tokenB), amountOut, takerData);

        console.log("ExactOut - Amount out requested:", amountOut);
        console.log("ExactOut - Amount in required:", amountIn);

        // Verify the ExactOut calculation is consistent:
        // The amountIn should be greater than what standard CP would require (due to fee)
        // Standard CP: amountIn = amountOut * balanceIn / (balanceOut - amountOut)
        uint256 cpAmountIn = amountOut * poolA / (poolB - amountOut);
        assertGt(amountIn, cpAmountIn, "ExactOut amountIn should be > CP baseline due to fee");
        
        console.log("CP baseline amountIn:", cpAmountIn);
        console.log("Fee impact (extra input):", amountIn - cpAmountIn);
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

    function test_XYCSwapStrictAdditive_RoundingInvariants() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(997_000_000); // 0.997

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwap
        );
    }

    function test_XYCSwapStrictAdditive_RoundingInvariants_HighFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint32 alpha = uint32(950_000_000); // 0.95 (5% fee)

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, alpha);
        bytes memory takerData = _signAndPack(order, true, 0);

        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwap
        );
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
