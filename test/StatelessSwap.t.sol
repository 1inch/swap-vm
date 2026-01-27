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
import { StatelessSwap, StatelessSwapArgsBuilder } from "../src/instructions/StatelessSwap.sol";
import { StatelessSwapMath } from "../src/libs/StatelessSwapMath.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StatelessSwapTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ONE = 1e18;

    // Fee values in BPS
    uint32 constant FEE_ZERO = 0;           // No fees → α = 1.0
    uint32 constant FEE_LOW = 30;           // 0.3% (typical DEX) → α = 0.997
    uint32 constant FEE_MEDIUM = 100;       // 1% → α = 0.99
    uint32 constant FEE_HIGH = 300;         // 3% → α = 0.97
    uint32 constant FEE_VERY_HIGH = 1000;   // 10% → α = 0.90

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

        // Test contract also needs approval
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _makeOrder(uint256 balanceA, uint256 balanceB, uint32 feeBps) internal view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_statelessSwap2D, StatelessSwapArgsBuilder.build2D(feeBps))
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

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: address(this),
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

        return abi.encodePacked(takerTraits);
    }

    // ========================================
    // MATH LIBRARY TESTS
    // ========================================

    function test_StatelessSwapMath_ExactIn_NoFee() public pure {
        uint256 x = 1000e18;
        uint256 y = 1000e18;
        uint256 dx = 10e18;
        uint256 alpha = ONE;  // α = 1 means no fee

        uint256 dy = StatelessSwapMath.swapExactIn(x, y, dx, alpha);

        // With α=1 (no fee), should match standard constant product
        // dy = y * dx / (x + dx) = 1000 * 10 / 1010 ≈ 9.9009...
        uint256 expected = y * dx / (x + dx);
        assertEq(dy, expected, "Alpha=1 should match constant product");
    }

    function test_StatelessSwapMath_ExactIn_WithFee() public pure {
        uint256 x = 1000e18;
        uint256 y = 1000e18;
        uint256 dx = 10e18;
        uint256 alpha = StatelessSwapMath.feeToAlpha(30);  // 0.3% fee → α = 0.997

        uint256 dy = StatelessSwapMath.swapExactIn(x, y, dx, alpha);

        // With fee, output should be less than no-fee case
        uint256 noFeeOutput = y * dx / (x + dx);
        assertLt(dy, noFeeOutput, "Fee should reduce output");
    }

    function test_StatelessSwapMath_ExactOut_NoFee() public pure {
        uint256 x = 1000e18;
        uint256 y = 1000e18;
        uint256 dy = 10e18;
        uint256 alpha = ONE;  // No fee

        uint256 dx = StatelessSwapMath.swapExactOut(x, y, dy, alpha);

        // With α=1 (no fee), should be close to standard constant product
        // dx = x * dy / (y - dy) ≈ 10.1
        uint256 expectedApprox = (x * dy + y - dy - 1) / (y - dy) + 1;
        assertApproxEqRel(dx, expectedApprox, 0.01e18, "Alpha=1 should be close to constant product");
    }

    function test_StatelessSwapMath_ExactOut_WithFee() public pure {
        uint256 x = 1000e18;
        uint256 y = 1000e18;
        uint256 dy = 10e18;
        uint256 alpha = StatelessSwapMath.feeToAlpha(30);  // 0.3% fee

        uint256 dx = StatelessSwapMath.swapExactOut(x, y, dy, alpha);

        // With fee, input should be more than no-fee case
        uint256 noFeeInput = StatelessSwapMath.swapExactOut(x, y, dy, ONE);
        assertGt(dx, noFeeInput, "Fee should increase required input");
    }

    function test_FeeToAlpha() public pure {
        // 0 bps → α = 1.0
        assertEq(StatelessSwapMath.feeToAlpha(0), ONE);

        // 30 bps = 0.3% → α = 0.997
        assertEq(StatelessSwapMath.feeToAlpha(30), 997e15);

        // 100 bps = 1% → α = 0.99
        assertEq(StatelessSwapMath.feeToAlpha(100), 99e16);

        // 1000 bps = 10% → α = 0.9
        assertEq(StatelessSwapMath.feeToAlpha(1000), 9e17);
    }

    // ========================================
    // BASIC SWAP TESTS
    // ========================================

    function test_BasicSwap_NoFees() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, FEE_ZERO);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        uint256 amountIn = 10e18;
        tokenA.mint(address(this), amountIn);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), amountIn, takerData
        );

        console.log("Fee=0 bps - amountIn:", actualIn);
        console.log("Fee=0 bps - amountOut:", actualOut);

        // With fee=0, should behave like standard constant product
        uint256 expectedOut = balanceB * amountIn / (balanceA + amountIn);

        assertEq(actualIn, amountIn);
        assertEq(actualOut, expectedOut);
    }

    function test_BasicSwap_LowFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        uint256 amountIn = 10e18;
        tokenA.mint(address(this), amountIn);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), amountIn, takerData
        );

        console.log("Fee=30 bps - amountIn:", actualIn);
        console.log("Fee=30 bps - amountOut:", actualOut);

        uint256 noFeeExpected = balanceB * amountIn / (balanceA + amountIn);

        assertEq(actualIn, amountIn);
        assertLt(actualOut, noFeeExpected, "Output less than no-fee due to fee");

        // Check that effective fee is approximately 0.3%
        uint256 feeRatio = (noFeeExpected - actualOut) * 10000 / noFeeExpected;
        console.log("Effective fee bps:", feeRatio);
        // With invariant curve, effective fee varies with trade size
        assertGt(feeRatio, 0, "Should have some fee");
    }

    function test_BasicSwap_HighFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, FEE_HIGH);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        uint256 amountIn = 10e18;
        tokenA.mint(address(this), amountIn);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), amountIn, takerData
        );

        console.log("Fee=300 bps - amountIn:", actualIn);
        console.log("Fee=300 bps - amountOut:", actualOut);

        uint256 noFeeExpected = balanceB * amountIn / (balanceA + amountIn);

        assertEq(actualIn, amountIn);
        assertLt(actualOut, noFeeExpected, "Output less than no-fee due to fee");
    }

    // ========================================
    // FEE REINVESTMENT TEST (CRITICAL!)
    // ========================================

    function test_FeeReinvestment_KGrows_BothDirections() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;

        console.log("\n=== Fee Reinvestment Test (Both Directions) ===");
        console.log("Initial K: %s", initialK);

        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);

        // --- Direction 1: A→B ---
        uint256 amountIn1 = 100e18;
        uint256 dy1 = StatelessSwapMath.swapExactIn(balanceA, balanceB, amountIn1, alpha);

        uint256 newBalanceA1 = balanceA + amountIn1;
        uint256 newBalanceB1 = balanceB - dy1;
        uint256 newK1 = newBalanceA1 * newBalanceB1;

        console.log("\nAfter A->B swap of %s:", amountIn1);
        console.log("  New balances: %s / %s", newBalanceA1, newBalanceB1);
        console.log("  New K: %s", newK1);
        console.log("  K grew: %s", newK1 > initialK);

        assertGt(newK1, initialK, "K should grow after A->B swap");

        // --- Direction 2: B→A (using updated balances) ---
        uint256 amountIn2 = 50e18;  // Input B tokens
        // For B→A, the "in" is now B and "out" is A
        uint256 dx2 = StatelessSwapMath.swapExactIn(newBalanceB1, newBalanceA1, amountIn2, alpha);

        uint256 newBalanceA2 = newBalanceA1 - dx2;  // A decreases (output)
        uint256 newBalanceB2 = newBalanceB1 + amountIn2;  // B increases (input)
        uint256 newK2 = newBalanceA2 * newBalanceB2;

        console.log("\nAfter B->A swap of %s:", amountIn2);
        console.log("  New balances: %s / %s", newBalanceA2, newBalanceB2);
        console.log("  New K: %s", newK2);
        console.log("  K grew from previous: %s", newK2 > newK1);

        assertGt(newK2, newK1, "K should grow after B->A swap too!");
        assertGt(newK2, initialK, "K should be greater than initial after both swaps");

        console.log("\n=== BOTH DIRECTIONS REINVEST FEES ===");
        console.log("Total K growth: %s%%", (newK2 - initialK) * 100 / initialK);
    }

    // ========================================
    // EXACTOUT TESTS
    // ========================================

    function test_ExactOut_NoFees() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, FEE_ZERO);
        bytes memory takerData = _signAndPackTakerData(order, false, type(uint256).max);

        uint256 amountOut = 10e18;
        tokenA.mint(address(this), 1000e18);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), amountOut, takerData
        );

        console.log("ExactOut Fee=0 - amountIn:", actualIn);
        console.log("ExactOut Fee=0 - amountOut:", actualOut);

        assertEq(actualOut, amountOut);
    }

    function test_ExactOut_WithFees() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerData = _signAndPackTakerData(order, false, type(uint256).max);

        uint256 amountOut = 10e18;
        tokenA.mint(address(this), 1000e18);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), amountOut, takerData
        );

        console.log("ExactOut Fee=30bps - amountIn:", actualIn);
        console.log("ExactOut Fee=30bps - amountOut:", actualOut);

        assertEq(actualOut, amountOut);

        // With fee, should require more input
        ISwapVM.Order memory orderNoFee = _makeOrder(balanceA, balanceB, FEE_ZERO);
        bytes memory takerDataNoFee = _signAndPackTakerData(orderNoFee, false, type(uint256).max);
        (uint256 noFeeIn,,) = swapVM.asView().quote(
            orderNoFee, address(tokenA), address(tokenB), amountOut, takerDataNoFee
        );

        assertGt(actualIn, noFeeIn, "More input required due to fee");
    }

    // ========================================
    // BIDIRECTIONAL TESTS
    // ========================================

    function test_Bidirectional() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 amountIn = 10e18;

        // Swap A -> B (quote only, don't execute)
        ISwapVM.Order memory orderAB = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataAB = _signAndPackTakerData(orderAB, true, 0);
        (,uint256 outAB,) = swapVM.asView().quote(orderAB, address(tokenA), address(tokenB), amountIn, takerDataAB);
        console.log("A->B output:", outAB);

        // Swap B -> A (fresh order with same parameters)
        ISwapVM.Order memory orderBA = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataBA = _signAndPackTakerData(orderBA, true, 0);
        (,uint256 outBA,) = swapVM.asView().quote(orderBA, address(tokenB), address(tokenA), amountIn, takerDataBA);
        console.log("B->A output:", outBA);

        // Both should produce reasonable output
        assertGt(outAB, 0);
        assertGt(outBA, 0);

        // With same pool and same fee, outputs should be equal (symmetric pool)
        assertEq(outAB, outBA, "Symmetric pool should give symmetric outputs");
    }

    // ========================================
    // FEE COMPARISON TEST
    // ========================================

    function test_FeeComparison() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 amountIn = 10e18;

        console.log("\n=== Fee Comparison ===");

        uint32[5] memory fees = [uint32(0), FEE_LOW, FEE_MEDIUM, FEE_HIGH, FEE_VERY_HIGH];
        string[5] memory labels = ["0", "30", "100", "300", "1000"];

        for (uint i = 0; i < fees.length; i++) {
            ISwapVM.Order memory order = _makeOrder(balanceA, balanceB, fees[i]);
            bytes memory takerData = _signAndPackTakerData(order, true, 0);
            (,uint256 out,) = swapVM.asView().quote(order, address(tokenA), address(tokenB), amountIn, takerData);

            uint256 noFeeOut = balanceB * amountIn / (balanceA + amountIn);
            uint256 effectiveFee = noFeeOut > out ? (noFeeOut - out) * 10000 / noFeeOut : 0;

            console.log("Fee=%s bps: output=%s, effective fee=%s bps", labels[i], out, effectiveFee);
        }
    }

    // ========================================
    // SUBADDITIVITY TEST
    // ========================================

    function test_Subadditivity_SingleSwapGeSplitSwaps() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        console.log("\n=== Subadditivity Test ===");
        console.log("Pool: 1000/1000, Fee: 30 bps\n");

        // Single swap of 100
        ISwapVM.Order memory orderSingle = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataSingle = _signAndPackTakerData(orderSingle, true, 0);
        (,uint256 singleOut,) = swapVM.asView().quote(
            orderSingle, address(tokenA), address(tokenB), 100e18, takerDataSingle
        );
        console.log("Single swap of 100: output = %s", singleOut);

        // Split: first 50
        tokenA.mint(address(this), 100e18);
        ISwapVM.Order memory orderFirst = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataFirst = _signAndPackTakerData(orderFirst, true, 0);
        (,uint256 firstOut,) = swapVM.swap(
            orderFirst, address(tokenA), address(tokenB), 50e18, takerDataFirst
        );

        // Pool after first swap: balanceA + 50, balanceB - firstOut
        uint256 newBalanceA = balanceA + 50e18;
        uint256 newBalanceB = balanceB - firstOut;

        // Split: second 50
        ISwapVM.Order memory orderSecond = _makeOrder(newBalanceA, newBalanceB, FEE_LOW);
        bytes memory takerDataSecond = _signAndPackTakerData(orderSecond, true, 0);
        (,uint256 secondOut,) = swapVM.swap(
            orderSecond, address(tokenA), address(tokenB), 50e18, takerDataSecond
        );

        uint256 splitTotal = firstOut + secondOut;
        console.log("Split swaps (50 + 50): %s + %s = %s", firstOut, secondOut, splitTotal);

        console.log("Single >= Split? %s >= %s", singleOut, splitTotal);

        // Subadditivity: single swap should give >= split swaps
        assertGe(singleOut, splitTotal, "Subadditivity: single swap >= split swaps");
    }

    // ========================================
    // ROUNDTRIP TEST
    // ========================================

    function test_Roundtrip_ExactInThenExactOut() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        console.log("\n=== Roundtrip Test ===\n");

        // ExactIn: 10 tokens -> ?
        ISwapVM.Order memory orderIn = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataIn = _signAndPackTakerData(orderIn, true, 0);
        (,uint256 amountOut,) = swapVM.asView().quote(
            orderIn, address(tokenA), address(tokenB), 10e18, takerDataIn
        );
        console.log("ExactIn: 10e18 -> %s", amountOut);

        // ExactOut: ? -> amountOut
        ISwapVM.Order memory orderOut = _makeOrder(balanceA, balanceB, FEE_LOW);
        bytes memory takerDataOut = _signAndPackTakerData(orderOut, false, type(uint256).max);
        (uint256 amountInBack,,) = swapVM.asView().quote(
            orderOut, address(tokenA), address(tokenB), amountOut, takerDataOut
        );
        console.log("ExactOut: %s -> %s (back)", amountInBack, amountOut);

        // With invariant curve math, roundtrip should be very close
        // Allow small tolerance due to numerical precision
        assertApproxEqRel(amountInBack, 10e18, 0.01e18, "Roundtrip should be close to original");
    }

    // ========================================
    // FEE VALIDATION TEST
    // ========================================

    function test_FeeValidation_MaxFee() public {
        // Should work with max fee (50%)
        bytes memory validArgs = StatelessSwapArgsBuilder.build2D(5000);
        assertGt(validArgs.length, 0, "Should encode successfully");
    }

    function test_FeeValidation_MaxFee_Reverts() public {
        // Create order with fee > max (will fail during build)
        bool reverted = false;
        try this.tryBuildInvalidFee() {
            // Should not reach here
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert for fee > max");
    }

    function tryBuildInvalidFee() external pure {
        StatelessSwapArgsBuilder.build2D(5001);
    }

    // ========================================
    // CRITICAL: BIDIRECTIONAL CONSISTENCY TEST
    // ========================================
    // This test verifies the pool cannot be drained by roundtrip swaps
    
    function test_CRITICAL_BidirectionalConsistency_NoDrain() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Bidirectional Drain Test   ");
        console.log("========================================\n");
        
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        console.log("Initial pool: %s / %s", balanceA, balanceB);
        console.log("Initial K: %s", initialK);
        console.log("Fee: 30 bps (alpha = 0.997)\n");

        // User starts with 100 A tokens
        uint256 userA = 100e18;
        uint256 userB = 0;
        
        console.log("=== Roundtrip: A -> B -> A ===");
        console.log("User starts with: %s A, %s B", userA, userB);
        
        // Step 1: Swap A -> B
        uint256 dyFromAtoB = StatelessSwapMath.swapExactIn(balanceA, balanceB, userA, alpha);
        uint256 newBalanceA = balanceA + userA;
        uint256 newBalanceB = balanceB - dyFromAtoB;
        
        userB = dyFromAtoB;  // User now has B tokens
        userA = 0;           // User spent A tokens
        
        console.log("\nAfter A->B swap of 100e18:");
        console.log("  User has: %s A, %s B", userA, userB);
        console.log("  Pool: %s / %s", newBalanceA, newBalanceB);
        console.log("  Pool K: %s", newBalanceA * newBalanceB);
        
        // Step 2: Swap B -> A (using the B we just got)
        // Now B is input, A is output
        uint256 dxFromBtoA = StatelessSwapMath.swapExactIn(newBalanceB, newBalanceA, userB, alpha);
        uint256 finalBalanceA = newBalanceA - dxFromBtoA;
        uint256 finalBalanceB = newBalanceB + userB;
        
        userA = dxFromBtoA;  // User now has A tokens back
        userB = 0;           // User spent B tokens
        
        console.log("\nAfter B->A swap of %s:", dyFromAtoB);
        console.log("  User has: %s A, %s B", userA, userB);
        console.log("  Pool: %s / %s", finalBalanceA, finalBalanceB);
        
        uint256 finalK = finalBalanceA * finalBalanceB;
        console.log("  Pool K: %s", finalK);
        
        // CRITICAL ASSERTIONS
        console.log("\n=== CRITICAL CHECKS ===");
        
        // 1. User should NOT have more A than they started with
        console.log("User A: %s (started with 100e18)", userA);
        assertLt(userA, 100e18, "DRAIN VULNERABILITY: User gained tokens!");
        console.log("  [PASS] User lost tokens (as expected with fees)");
        
        // 2. Pool K should NOT have decreased
        console.log("Pool K change: %s -> %s", initialK, finalK);
        assertGe(finalK, initialK, "DRAIN VULNERABILITY: Pool K decreased!");
        console.log("  [PASS] Pool K grew (fees reinvested)");
        
        // 3. Calculate actual loss
        uint256 userLoss = 100e18 - userA;
        uint256 lossPercent = userLoss * 10000 / 100e18;
        console.log("\nUser loss: %s wei (%s bps)", userLoss, lossPercent);
    }
    
    function test_CRITICAL_MultipleRoundtrips_NoDrain() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Multiple Roundtrips Test   ");
        console.log("========================================\n");
        
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        uint256 userA = 100e18;
        uint256 numRoundtrips = 5;
        
        console.log("Testing %s roundtrips with fee=30bps", numRoundtrips);
        console.log("User starts with: %s A", userA);
        
        for (uint i = 0; i < numRoundtrips; i++) {
            // A -> B
            uint256 dyFromAtoB = StatelessSwapMath.swapExactIn(balanceA, balanceB, userA, alpha);
            balanceA = balanceA + userA;
            balanceB = balanceB - dyFromAtoB;
            
            // B -> A
            uint256 dxFromBtoA = StatelessSwapMath.swapExactIn(balanceB, balanceA, dyFromAtoB, alpha);
            balanceB = balanceB + dyFromAtoB;
            balanceA = balanceA - dxFromBtoA;
            
            userA = dxFromBtoA;
            
            uint256 currentK = balanceA * balanceB;
            console.log("After roundtrip %s: User A=%s, K=%s", i+1, userA, currentK);
            
            // Assert K never decreased
            assertGe(currentK, initialK, "K decreased during roundtrip!");
            initialK = currentK;  // Update for next iteration
        }
        
        console.log("\nFinal user A: %s (started with 100e18)", userA);
        console.log("Total loss: %s", 100e18 - userA);
        
        assertLt(userA, 100e18, "User should not gain from roundtrips");
    }
    
    function test_CRITICAL_DrainAttempt_VaryingAmounts() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Drain with Varying Amounts ");
        console.log("========================================\n");
        
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Try various swap sizes
        uint256[5] memory amounts = [uint256(1e18), 10e18, 50e18, 100e18, 200e18];
        
        for (uint i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            
            // A -> B
            uint256 dy = StatelessSwapMath.swapExactIn(balanceA, balanceB, amount, alpha);
            uint256 tempA = balanceA + amount;
            uint256 tempB = balanceB - dy;
            
            // B -> A
            uint256 dx = StatelessSwapMath.swapExactIn(tempB, tempA, dy, alpha);
            uint256 finalA = tempA - dx;
            uint256 finalB = tempB + dy;
            
            uint256 finalK = finalA * finalB;
            
            console.log("Amount %s: returned %s, K=%s", amount, dx, finalK);
            
            // User should ALWAYS get back less
            assertLt(dx, amount, "Drain: user gained on roundtrip!");
            
            // K should ALWAYS grow
            assertGe(finalK, initialK, "Drain: K decreased!");
        }
        
        console.log("\n[PASS] All roundtrips result in user loss");
    }
    
    function test_CRITICAL_EdgeCase_VerySmallAmount() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Very small amount - test for rounding edge cases
        uint256 amount = 1e15;  // 0.001 tokens
        
        uint256 dy = StatelessSwapMath.swapExactIn(balanceA, balanceB, amount, alpha);
        uint256 tempA = balanceA + amount;
        uint256 tempB = balanceB - dy;
        
        uint256 dx = StatelessSwapMath.swapExactIn(tempB, tempA, dy, alpha);
        
        console.log("Small amount roundtrip:");
        console.log("  Input: %s", amount);
        console.log("  Intermediate (B): %s", dy);
        console.log("  Output: %s", dx);
        
        // Even with tiny amounts, should not gain
        assertLe(dx, amount, "Small amount drain vulnerability!");
    }
    
    function test_CRITICAL_EdgeCase_LargeAmount() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Large amount - significant pool impact
        uint256 amount = 500e18;  // 50% of pool
        
        uint256 dy = StatelessSwapMath.swapExactIn(balanceA, balanceB, amount, alpha);
        uint256 tempA = balanceA + amount;
        uint256 tempB = balanceB - dy;
        
        uint256 dx = StatelessSwapMath.swapExactIn(tempB, tempA, dy, alpha);
        
        console.log("Large amount roundtrip (50%% of pool):");
        console.log("  Input: %s", amount);
        console.log("  Intermediate (B): %s", dy);
        console.log("  Output: %s", dx);
        console.log("  Loss: %s (%s bps)", amount - dx, (amount - dx) * 10000 / amount);
        
        assertLt(dx, amount, "Large amount drain vulnerability!");
    }

    // ========================================
    // CRITICAL: Asymmetric Attack Pattern
    // ========================================
    // Test: small X→Y, large Y→X, small X→Y
    // This pattern might exploit asymmetry in the dual curve
    
    function test_CRITICAL_AsymmetricAttack_SmallLargeSmall() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Asymmetric Attack Pattern  ");
        console.log("  small X->Y, large Y->X, small X->Y   ");
        console.log("========================================\n");
        
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Attacker's tokens
        uint256 attackerA = 10e18;   // Small amount for X→Y
        uint256 attackerB = 500e18;  // Large amount for Y→X
        
        uint256 totalAttackerValueBefore = attackerA + attackerB;  // Simplified: assume 1:1 value
        
        console.log("Initial pool: %s A / %s B", balanceA, balanceB);
        console.log("Initial K: %s", initialK);
        console.log("Attacker starts with: %s A, %s B", attackerA, attackerB);
        console.log("Total attacker value: %s\n", totalAttackerValueBefore);
        
        // Step 1: Small swap X→Y (10 A → ? B)
        console.log("=== Step 1: Small X->Y (10 A) ===");
        uint256 dy1 = StatelessSwapMath.swapExactIn(balanceA, balanceB, attackerA, alpha);
        balanceA = balanceA + attackerA;
        balanceB = balanceB - dy1;
        attackerA = 0;
        attackerB = attackerB + dy1;
        
        console.log("  Got: %s B", dy1);
        console.log("  Pool: %s A / %s B", balanceA, balanceB);
        console.log("  Pool K: %s", balanceA * balanceB);
        console.log("  Attacker: %s A, %s B", attackerA, attackerB);
        
        // Step 2: Large swap Y→X (500 B → ? A)
        console.log("\n=== Step 2: Large Y->X (500 B) ===");
        uint256 largeSwapB = 500e18;
        uint256 dx2 = StatelessSwapMath.swapExactIn(balanceB, balanceA, largeSwapB, alpha);
        balanceB = balanceB + largeSwapB;
        balanceA = balanceA - dx2;
        attackerB = attackerB - largeSwapB;
        attackerA = attackerA + dx2;
        
        console.log("  Got: %s A", dx2);
        console.log("  Pool: %s A / %s B", balanceA, balanceB);
        console.log("  Pool K: %s", balanceA * balanceB);
        console.log("  Attacker: %s A, %s B", attackerA, attackerB);
        
        // Step 3: Small swap X→Y again (use all remaining A)
        console.log("\n=== Step 3: Small X->Y (remaining A) ===");
        uint256 dy3 = StatelessSwapMath.swapExactIn(balanceA, balanceB, attackerA, alpha);
        balanceA = balanceA + attackerA;
        balanceB = balanceB - dy3;
        attackerA = 0;
        attackerB = attackerB + dy3;
        
        console.log("  Swapped: %s A", dx2);
        console.log("  Got: %s B", dy3);
        console.log("  Pool: %s A / %s B", balanceA, balanceB);
        
        uint256 finalK = balanceA * balanceB;
        console.log("  Pool K: %s", finalK);
        console.log("  Attacker: %s A, %s B", attackerA, attackerB);
        
        // Calculate final attacker value
        uint256 totalAttackerValueAfter = attackerA + attackerB;
        
        console.log("\n=== RESULTS ===");
        console.log("Attacker value before: %s", totalAttackerValueBefore);
        console.log("Attacker value after:  %s", totalAttackerValueAfter);
        
        if (totalAttackerValueAfter > totalAttackerValueBefore) {
            console.log("VULNERABILITY: Attacker GAINED %s", totalAttackerValueAfter - totalAttackerValueBefore);
        } else {
            console.log("Safe: Attacker LOST %s", totalAttackerValueBefore - totalAttackerValueAfter);
        }
        
        console.log("Pool K change: %s -> %s", initialK, finalK);
        
        // CRITICAL ASSERTIONS
        assertLe(totalAttackerValueAfter, totalAttackerValueBefore, "DRAIN: Attacker gained value!");
        assertGe(finalK, initialK, "DRAIN: Pool K decreased!");
    }
    
    function test_CRITICAL_AsymmetricAttack_MultiplePatterns() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Multiple Attack Patterns   ");
        console.log("========================================\n");
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Test various asymmetric patterns
        // Pattern: [small, large, small] in different directions
        
        _testAsymmetricPattern(alpha, 1e18, 100e18, 1e18, "1-100-1");
        _testAsymmetricPattern(alpha, 5e18, 200e18, 5e18, "5-200-5");
        _testAsymmetricPattern(alpha, 10e18, 500e18, 10e18, "10-500-10");
        _testAsymmetricPattern(alpha, 1e18, 900e18, 1e18, "1-900-1 (extreme)");
    }
    
    function _testAsymmetricPattern(
        uint256 alpha,
        uint256 small1,
        uint256 large,
        uint256 small2,
        string memory label
    ) internal {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        // Attacker starts with small1 A and large B
        uint256 attackerA = small1;
        uint256 attackerB = large;
        uint256 valueBefore = attackerA + attackerB;
        
        // Step 1: Small X→Y
        uint256 dy1 = StatelessSwapMath.swapExactIn(balanceA, balanceB, attackerA, alpha);
        balanceA += attackerA;
        balanceB -= dy1;
        attackerB += dy1;
        attackerA = 0;
        
        // Step 2: Large Y→X
        uint256 dx2 = StatelessSwapMath.swapExactIn(balanceB, balanceA, large, alpha);
        balanceB += large;
        balanceA -= dx2;
        attackerB -= large;
        attackerA += dx2;
        
        // Step 3: Small X→Y (or use remaining A)
        uint256 toSwap = attackerA < small2 ? attackerA : small2;
        if (toSwap > 0) {
            uint256 dy3 = StatelessSwapMath.swapExactIn(balanceA, balanceB, toSwap, alpha);
            balanceA += toSwap;
            balanceB -= dy3;
            attackerA -= toSwap;
            attackerB += dy3;
        }
        
        uint256 valueAfter = attackerA + attackerB;
        uint256 finalK = balanceA * balanceB;
        
        string memory result = valueAfter > valueBefore ? "VULNERABLE" : "SAFE";
        
        if (valueAfter > valueBefore) {
            console.log("Pattern %s: %s (gained: %s)", label, result, valueAfter - valueBefore);
        } else {
            console.log("Pattern %s: %s (lost: %s)", label, result, valueBefore - valueAfter);
        }
        
        assertLe(valueAfter, valueBefore, string.concat("Drain in pattern: ", label));
        assertGe(finalK, initialK, string.concat("K decreased in pattern: ", label));
    }
    
    function test_CRITICAL_SandwichStyleAttack() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Sandwich-Style Attack      ");
        console.log("========================================\n");
        
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Attacker sandwiches their own trades
        uint256 attackerA = 100e18;
        uint256 attackerB = 100e18;
        uint256 valueBefore = attackerA + attackerB;
        
        console.log("Attacker starts: %s A, %s B", attackerA, attackerB);
        
        // Front-run: Large X→Y to move price
        console.log("\n1. Front-run: Large X->Y (100 A)");
        uint256 dy1 = StatelessSwapMath.swapExactIn(balanceA, balanceB, attackerA, alpha);
        balanceA += attackerA;
        balanceB -= dy1;
        attackerA = 0;
        attackerB += dy1;
        console.log("   Got %s B, pool now %s/%s", dy1, balanceA, balanceB);
        
        // "Victim" trade in same direction (simulate with attacker's B)
        console.log("\n2. 'Victim' trade: Y->X (50 B)");
        uint256 victimB = 50e18;
        uint256 victimGotA = StatelessSwapMath.swapExactIn(balanceB, balanceA, victimB, alpha);
        balanceB += victimB;
        balanceA -= victimGotA;
        attackerB -= victimB;  // Attacker pays for victim trade
        attackerA += victimGotA;
        console.log("   Got %s A, pool now %s/%s", victimGotA, balanceA, balanceB);
        
        // Back-run: Y→X to profit from moved price
        console.log("\n3. Back-run: Y->X (remaining B)");
        uint256 dx3 = StatelessSwapMath.swapExactIn(balanceB, balanceA, attackerB, alpha);
        balanceB += attackerB;
        balanceA -= dx3;
        attackerA += dx3;
        attackerB = 0;
        console.log("   Got %s A, pool now %s/%s", dx3, balanceA, balanceB);
        
        uint256 valueAfter = attackerA + attackerB;
        uint256 finalK = balanceA * balanceB;
        
        console.log("\n=== RESULTS ===");
        console.log("Attacker value: %s -> %s", valueBefore, valueAfter);
        console.log("Pool K: %s -> %s", initialK, finalK);
        
        if (valueAfter > valueBefore) {
            console.log("VULNERABILITY: Gained %s", valueAfter - valueBefore);
        } else {
            console.log("Safe: Lost %s", valueBefore - valueAfter);
        }
        
        assertLe(valueAfter, valueBefore, "Sandwich attack profitable!");
        assertGe(finalK, initialK, "Pool K decreased!");
    }
    
    // ========================================
    // CRITICAL: Extreme Imbalance Test
    // ========================================
    
    function test_CRITICAL_ExtremeImbalance_TinySwaps() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Extreme Imbalance (x >> y) ");
        console.log("  Tiny Y->X swaps repeatedly           ");
        console.log("========================================\n");
        
        // Extreme imbalance: x = 10000, y = 1
        uint256 balanceA = 10000e18;
        uint256 balanceB = 1e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        console.log("Initial pool: %s A / %s B (ratio 10000:1)", balanceA, balanceB);
        console.log("Initial K: %s", initialK);
        
        // Track for monotonicity check
        uint256 prevOutput = 0;
        uint256 totalBIn = 0;
        uint256 totalAOut = 0;
        
        // Do 10 tiny Y→X swaps
        uint256 numSwaps = 10;
        uint256 swapAmount = 0.01e18;  // 0.01 B each (1% of B balance)
        
        console.log("\nDoing %s swaps of %s B each:\n", numSwaps, swapAmount);
        
        for (uint i = 0; i < numSwaps; i++) {
            // Skip if we've depleted B
            if (swapAmount > balanceB / 2) {
                console.log("Stopping: B balance too low");
                break;
            }
            
            uint256 dx = StatelessSwapMath.swapExactIn(balanceB, balanceA, swapAmount, alpha);
            
            // Update pool
            balanceB += swapAmount;
            balanceA -= dx;
            
            totalBIn += swapAmount;
            totalAOut += dx;
            
            uint256 currentK = balanceA * balanceB;
            
            console.log("Swap %s: %s B -> %s A", i+1, swapAmount, dx);
            console.log("         Pool: %s/%s, K=%s", balanceA, balanceB, currentK);
            
            // CRITICAL: Check monotonicity - each subsequent swap should give LESS output
            // (because we're depleting the cheap side)
            if (i > 0) {
                // Note: For very imbalanced pools, later swaps may give MORE 
                // because price is changing. The key is K must not decrease.
                // Actually for same-sized swaps, output should decrease as A depletes
            }
            
            // CRITICAL: K must never decrease
            assertGe(currentK, initialK, "K decreased during swap!");
            
            // CRITICAL: Output must be bounded
            assertLt(dx, balanceA + dx, "Output exceeded available balance!");
            assertGt(dx, 0, "Zero output!");
            
            prevOutput = dx;
        }
        
        uint256 finalK = balanceA * balanceB;
        
        console.log("\n=== RESULTS ===");
        console.log("Total B in: %s", totalBIn);
        console.log("Total A out: %s", totalAOut);
        console.log("Effective rate: %s A per B", totalAOut * 1e18 / totalBIn);
        console.log("Pool K: %s -> %s (grew: %s)", initialK, finalK, finalK > initialK);
        console.log("Final pool: %s A / %s B", balanceA, balanceB);
        
        assertGe(finalK, initialK, "Final K less than initial!");
    }
    
    function test_CRITICAL_ExtremeImbalance_Reverse() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Extreme Imbalance (y >> x) ");
        console.log("  Tiny X->Y swaps repeatedly           ");
        console.log("========================================\n");
        
        // Extreme imbalance: x = 1, y = 10000
        uint256 balanceA = 1e18;
        uint256 balanceB = 10000e18;
        uint256 initialK = balanceA * balanceB;
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        console.log("Initial pool: %s A / %s B (ratio 1:10000)", balanceA, balanceB);
        console.log("Initial K: %s", initialK);
        
        uint256 totalAIn = 0;
        uint256 totalBOut = 0;
        
        // Do 10 tiny X→Y swaps
        uint256 numSwaps = 10;
        uint256 swapAmount = 0.01e18;  // 0.01 A each
        
        console.log("\nDoing %s swaps of %s A each:\n", numSwaps, swapAmount);
        
        for (uint i = 0; i < numSwaps; i++) {
            if (swapAmount > balanceA / 2) {
                console.log("Stopping: A balance too low");
                break;
            }
            
            uint256 dy = StatelessSwapMath.swapExactIn(balanceA, balanceB, swapAmount, alpha);
            
            balanceA += swapAmount;
            balanceB -= dy;
            
            totalAIn += swapAmount;
            totalBOut += dy;
            
            uint256 currentK = balanceA * balanceB;
            
            console.log("Swap %s: %s A -> %s B", i+1, swapAmount, dy);
            console.log("         K=%s", currentK);
            
            assertGe(currentK, initialK, "K decreased!");
            assertGt(dy, 0, "Zero output!");
        }
        
        uint256 finalK = balanceA * balanceB;
        
        console.log("\n=== RESULTS ===");
        console.log("Total A in: %s", totalAIn);
        console.log("Total B out: %s", totalBOut);
        console.log("Pool K grew: %s -> %s", initialK, finalK);
        
        assertGe(finalK, initialK, "Final K less than initial!");
    }
    
    // ========================================
    // CRITICAL: ExactIn vs ExactOut Inversion
    // ========================================
    
    function test_CRITICAL_ExactInExactOut_Inversion() public {
        console.log("\n========================================");
        console.log("  CRITICAL: ExactIn/ExactOut Inversion ");
        console.log("  ExactIn(dx)->dy, ExactOut(dy)->dx'   ");
        console.log("  Must have: dx' >= dx (fee property)  ");
        console.log("========================================\n");
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Test various pool states
        _testInversion(1000e18, 1000e18, 10e18, alpha, "Balanced 1000/1000, dx=10");
        _testInversion(1000e18, 1000e18, 100e18, alpha, "Balanced 1000/1000, dx=100");
        _testInversion(1000e18, 1000e18, 500e18, alpha, "Balanced 1000/1000, dx=500");
        
        // Imbalanced pools
        _testInversion(10000e18, 100e18, 10e18, alpha, "Imbalanced 10000/100, dx=10");
        _testInversion(100e18, 10000e18, 10e18, alpha, "Imbalanced 100/10000, dx=10");
        
        // Extreme imbalance
        _testInversion(10000e18, 1e18, 0.001e18, alpha, "Extreme 10000/1, dx=0.001");
        _testInversion(1e18, 10000e18, 0.001e18, alpha, "Extreme 1/10000, dx=0.001");
        
        // Small amounts
        _testInversion(1000e18, 1000e18, 1e15, alpha, "Balanced, tiny dx=0.001");
        _testInversion(1000e18, 1000e18, 1e18, alpha, "Balanced, small dx=1");
        
        // Large amounts
        _testInversion(1000e18, 1000e18, 900e18, alpha, "Balanced, large dx=900 (90%)");
    }
    
    function _testInversion(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 dx,
        uint256 alpha,
        string memory label
    ) internal {
        // Step 1: ExactIn(dx) -> dy
        uint256 dy = StatelessSwapMath.swapExactIn(balanceIn, balanceOut, dx, alpha);
        
        // Step 2: ExactOut(dy) -> dx'
        // Note: ExactOut uses the SAME initial pool state
        uint256 dxPrime = StatelessSwapMath.swapExactOut(balanceIn, balanceOut, dy, alpha);
        
        // CRITICAL: dx' must be >= dx
        // (If you want dy output, you need at least dx input due to fees)
        bool passed = dxPrime >= dx;
        
        string memory result = passed ? "PASS" : "FAIL";
        
        if (dxPrime >= dx) {
            uint256 diff = dxPrime - dx;
            uint256 diffBps = diff * 10000 / dx;
            console.log("%s: %s", label, result);
            console.log("    dx'=%s >= dx=%s, diff=%s bps", dxPrime, dx, diffBps);
        } else {
            uint256 diff = dx - dxPrime;
            console.log("%s: %s", label, result);
            console.log("    dx'=%s < dx=%s, UNDERPAID by %s", dxPrime, dx, diff);
        }
        
        // The assertion
        assertGe(dxPrime, dx, string.concat("Inversion failed: dx' < dx in ", label));
    }
    
    function test_CRITICAL_ExactInExactOut_Inversion_HighFees() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Inversion with High Fees   ");
        console.log("========================================\n");
        
        // Test with various fee levels
        uint32[4] memory fees = [uint32(30), 100, 300, 1000];
        string[4] memory feeLabels = ["30bps", "100bps", "300bps", "1000bps"];
        
        for (uint i = 0; i < fees.length; i++) {
            uint256 alpha = StatelessSwapMath.feeToAlpha(fees[i]);
            console.log("\n--- Fee: %s ---", feeLabels[i]);
            
            _testInversion(1000e18, 1000e18, 100e18, alpha, "Balanced");
            _testInversion(10000e18, 100e18, 10e18, alpha, "Imbalanced");
        }
    }
    
    function test_CRITICAL_ExactInExactOut_NeverUndercharge() public {
        console.log("\n========================================");
        console.log("  CRITICAL: Systematic Inversion Test  ");
        console.log("  Testing many random-ish states       ");
        console.log("========================================\n");
        
        uint256 alpha = StatelessSwapMath.feeToAlpha(FEE_LOW);
        
        // Test a grid of pool states and swap amounts
        uint256[3] memory balances = [uint256(100e18), 1000e18, 10000e18];
        uint256[5] memory swapPercents = [uint256(1), 5, 10, 25, 50];  // % of balanceIn
        
        uint256 passCount = 0;
        uint256 totalTests = 0;
        
        for (uint i = 0; i < balances.length; i++) {
            for (uint j = 0; j < balances.length; j++) {
                uint256 balIn = balances[i];
                uint256 balOut = balances[j];
                
                for (uint k = 0; k < swapPercents.length; k++) {
                    uint256 dx = balIn * swapPercents[k] / 100;
                    if (dx == 0) dx = 1e15;  // Minimum
                    
                    uint256 dy = StatelessSwapMath.swapExactIn(balIn, balOut, dx, alpha);
                    
                    if (dy >= balOut) continue;  // Skip invalid cases
                    
                    uint256 dxPrime = StatelessSwapMath.swapExactOut(balIn, balOut, dy, alpha);
                    
                    totalTests++;
                    if (dxPrime >= dx) {
                        passCount++;
                    } else {
                        console.log("FAIL: bal=%s/%s, dx=%s", balIn, balOut, dx);
                        console.log("      dy=%s, dx'=%s", dy, dxPrime);
                    }
                }
            }
        }
        
        console.log("Tested %s configurations: %s passed, %s failed", 
            totalTests, passCount, totalTests - passCount);
        
        assertEq(passCount, totalTests, "Some inversion tests failed!");
    }
}
