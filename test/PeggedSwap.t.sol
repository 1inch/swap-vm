// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

// Helper contract to test internal library functions
contract PeggedSwapMathWrapper {
    function solve(uint256 u, uint256 a, uint256 invariantC) external pure returns (uint256) {
        return PeggedSwapMath.solve(u, a, invariantC);
    }

    function computeInvariant(uint256 u, uint256 v, uint256 a) external pure returns (uint256) {
        return PeggedSwapMath.invariant(u, v, a);
    }

    function computeInvariantFromReserves(uint256 x, uint256 y, uint256 x0, uint256 y0, uint256 a) external pure returns (uint256) {
        return PeggedSwapMath.invariantFromReserves(x, y, x0, y0, a);
    }
}

contract PeggedSwapTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    struct PoolSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint256 x0;
        uint256 y0;
        uint256 linearWidth;
        uint256 feeInBps;
    }

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        TokenMock(tokenA).mint(maker, 1000000e18);
        TokenMock(tokenB).mint(maker, 1000000e18);
        TokenMock(tokenA).mint(taker, 1000000e18);
        TokenMock(tokenB).mint(taker, 1000000e18);

        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _createOrder(PoolSetup memory setup) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());

        bytes memory programBytes = bytes.concat(
            prog.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
            setup.feeInBps > 0 ? prog.build(Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(uint32(setup.feeInBps))) : bytes(""),
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: setup.x0,
                    y0: setup.y0,
                    linearWidth: setup.linearWidth,
                    rateLt: 1,
                    rateGt: 1
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

    function _makeTakerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
        return abi.encodePacked(TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
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
        })), signature);
    }

    function _signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _assertSwapQuoteConsistency(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn
    ) internal {
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(isExactIn, signature);

        // Quote
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order, tokenA, tokenB, amount, takerData
        );

        // Swap
        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(
            order, tokenA, tokenB, amount, takerData
        );

        assertEq(swappedIn, quotedIn, "Quote/Swap amountIn mismatch");
        assertEq(swappedOut, quotedOut, "Quote/Swap amountOut mismatch");
    }

    // ========================================
    // BASIC SWAP TESTS
    // ========================================

    function test_PeggedSwap_BasicSwap_ExactIn() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 1000e18;

        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        // Quote and swap
        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, takerData);

        // Sanity checks
        assertEq(swappedIn, amountIn);
        assertGt(swappedOut, 0, "Output must be positive");
        // For balanced pool with no fee, output should be close to input (1% of pool = minimal slippage)
        assertGe(swappedOut, amountIn * 99 / 100, "Output too low - excessive slippage");
        assertLe(swappedOut, amountIn, "Output exceeds input");
    }

    function test_PeggedSwap_BasicSwap_ExactOut() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountOut = 1000e18;

        _assertSwapQuoteConsistency(order, amountOut, false);
    }

    // ========================================
    // LINEAR WIDTH (PARAMETER A) TESTS
    // ========================================

    function test_PeggedSwap_LinearWidth_VariesPriceImpact() public {
        uint256 poolSize = 100000e18;
        uint256 swapSize = 5000e18; // 5% of pool

        // Test different A values
        uint256[5] memory linearWidths = [
            uint256(0),        // Pure sqrt, max slippage
            0.1e27,            // Low A, unpegged
            0.8e27,            // Medium A, stablecoins
            1.2e27,            // High A, pegged
            2e27               // Max A, minimal slippage
        ];

        uint256 previousOut = 0;

        for (uint256 i = 0; i < linearWidths.length; i++) {
            PoolSetup memory setup = PoolSetup({
                balanceA: poolSize,
                balanceB: poolSize,
                x0: poolSize,
                y0: poolSize,
                linearWidth: linearWidths[i],
                feeInBps: 0
            });

            ISwapVM.Order memory order = _createOrder(setup);
            bytes memory signature = _signOrder(order);
            bytes memory takerData = _makeTakerData(true, signature);

            vm.prank(taker);
            (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, swapSize, takerData);

            // Higher A should give better output (less slippage)
            if (i > 0) {
                assertGt(amountOut, previousOut, "Higher A should reduce slippage");
            }
            previousOut = amountOut;
        }
    }

    function test_PeggedSwap_EdgeCase_A_Zero() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0, // Pure sqrt curve
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 10000e18;

        _assertSwapQuoteConsistency(order, amountIn, true);

        // Verify invariant preservation
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, takerData);

        uint256 x1 = setup.balanceA + amountIn;
        uint256 y1 = setup.balanceB - amountOut;
        uint256 inv0 = PeggedSwapMath.invariantFromReserves(
            setup.balanceA, setup.balanceB, setup.x0, setup.y0, setup.linearWidth
        );
        uint256 inv1 = PeggedSwapMath.invariantFromReserves(
            x1, y1, setup.x0, setup.y0, setup.linearWidth
        );

        assertApproxEqAbs(inv0, inv1, 5e24, "Invariant should be preserved with dynamic balances");
    }

    function test_PeggedSwap_EdgeCase_A_Max() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 2e27, // Maximum allowed
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 10000e18;

        _assertSwapQuoteConsistency(order, amountIn, true);
    }

    // ========================================
    // IMBALANCED POOL TESTS
    // ========================================

    function test_PeggedSwap_ImbalancedPool() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 100000e18,
            balanceB: 90000e18, // 10% imbalance
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0.5e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 1000e18;

        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, takerData);

        // Sanity checks
        assertEq(swappedIn, amountIn);
        assertGt(swappedOut, 0, "Output must be positive");
        // Buying scarce token (B) - output should be less than input but reasonable
        assertGe(swappedOut, amountIn * 95 / 100, "Output too low for 10% imbalance");
        assertLe(swappedOut, amountIn, "Output should not exceed input");
    }

    function test_PeggedSwap_ExtremeImbalance() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 99000e18,
            balanceB: 1000e18, // 99:1 ratio
            x0: 99000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 100e18;

        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, takerData);

        // Sanity checks
        assertEq(swappedIn, amountIn);
        assertGt(swappedOut, 0, "Output must be positive");
        // With 99:1 ratio and medium A (0.8), curve still allows reasonable output
        assertLe(swappedOut, amountIn * 10, "Output too high - possible exploit");
        // Should get at least something
        assertGt(swappedOut, setup.balanceB / 1000, "Output too low - pool may be broken");
    }

    // ========================================
    // DIRECTION TESTS
    // ========================================

    function test_PeggedSwap_SwapAbundantForScarce() public {
        // Setup extremely imbalanced pool: 1M abundant : 1K scarce
        PoolSetup memory setup = PoolSetup({
            balanceA: 1_000_000e18,  // abundant
            balanceB: 1_000e18,      // scarce
            x0: 1_000_000e18,
            y0: 1_000e18,
            linearWidth: 0,  // pure sqrt curve
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        uint256 swapAmount = 10e18;

        // Swap abundant for scarce (A → B)
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, tokenA, tokenB, swapAmount, takerData
        );

        // Verify reasonable output bounds for abundant→scarce swap
        uint256 minReasonableOutput = swapAmount / 100;     // at least 0.1x
        uint256 maxReasonableOutput = swapAmount * 2;       // at most 2x

        assertEq(amountIn, swapAmount);
        assertGt(amountOut, 0);
        assertGe(amountOut, minReasonableOutput, "Output too low");
        assertLe(amountOut, maxReasonableOutput, "Output too high - possible axis mismatch");
    }

    function test_PeggedSwap_SwapScarceForAbundant() public {
        // Setup extremely imbalanced pool: 1M abundant : 1K scarce
        PoolSetup memory setup = PoolSetup({
            balanceA: 1_000_000e18,  // abundant
            balanceB: 1_000e18,      // scarce
            x0: 1_000_000e18,
            y0: 1_000e18,
            linearWidth: 0,  // pure sqrt curve
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        uint256 swapAmount = 10e18;

        // Swap scarce for abundant (B → A)
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, tokenB, tokenA, swapAmount, takerData
        );

        // Verify reasonable output bounds for scarce→abundant swap
        uint256 minReasonableOutput = swapAmount / 100;     // at least 0.1x
        uint256 maxReasonableOutput = swapAmount * 2;       // at most 2x

        assertEq(amountIn, swapAmount);
        assertGe(amountOut, minReasonableOutput, "Output too low");
        assertLe(amountOut, maxReasonableOutput, "Output too high - possible axis mismatch");
    }

    // ========================================
    // FEE TESTS
    // ========================================

    function test_PeggedSwap_WithFee() public {
        PoolSetup memory setupNoFee = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        PoolSetup memory setupWithFee = PoolSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            x0: 100000e18,
            y0: 100000e18,
            linearWidth: 0.8e27,
            feeInBps: 0.003e9 // 0.3%
        });

        ISwapVM.Order memory orderNoFee = _createOrder(setupNoFee);
        ISwapVM.Order memory orderWithFee = _createOrder(setupWithFee);

        uint256 amountIn = 5000e18;

        bytes memory signatureNoFee = _signOrder(orderNoFee);
        bytes memory takerDataNoFee = _makeTakerData(true, signatureNoFee);

        bytes memory signatureWithFee = _signOrder(orderWithFee);
        bytes memory takerDataWithFee = _makeTakerData(true, signatureWithFee);

        vm.prank(taker);
        (, uint256 amountOutNoFee,) = swapVM.swap(orderNoFee, tokenA, tokenB, amountIn, takerDataNoFee);

        vm.prank(taker);
        (, uint256 amountOutWithFee,) = swapVM.swap(orderWithFee, tokenA, tokenB, amountIn, takerDataWithFee);

        assertLt(amountOutWithFee, amountOutNoFee, "Fee should reduce output");
    }

    // ========================================
    // ROUNDING PROTECTION TESTS
    // ========================================

    function test_PeggedSwap_RoundingProtection_ExactIn() public {
        // Use smaller pool to make rounding effects more visible
        PoolSetup memory setup = PoolSetup({
            balanceA: 1000e18,
            balanceB: 1000e18,
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountIn = 1e15; // 0.001 tokens - small but meaningful

        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, amountIn, takerData);

        // Verify swap executed
        assertEq(swappedIn, amountIn);

        // Calculate what output would be without rounding protection (using Math.ceilDiv)
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            setup.balanceA, setup.balanceB, setup.x0, setup.y0, setup.linearWidth
        );
        uint256 x1 = setup.balanceA + amountIn;
        uint256 u1 = (x1 * PeggedSwapMath.ONE) / setup.x0;
        uint256 v1 = PeggedSwapMath.solve(u1, setup.linearWidth, targetInvariant);

        // Without protection: regular division (rounds DOWN y1 → rounds UP amountOut)
        uint256 y1_vulnerable = (v1 * setup.y0) / PeggedSwapMath.ONE;
        uint256 amountOut_vulnerable = setup.balanceB - y1_vulnerable;

        // With protection: ceilDiv (rounds UP y1 → rounds DOWN amountOut)
        uint256 y1_protected = Math.ceilDiv(v1 * setup.y0, PeggedSwapMath.ONE);
        uint256 amountOut_protected = setup.balanceB - y1_protected;

        // Actual swap should match the protected (safe) calculation
        assertEq(swappedOut, amountOut_protected, "Swap should use rounding protection");
        // Protected output should be <= vulnerable output (safer for maker)
        assertLe(amountOut_protected, amountOut_vulnerable, "Protection should not increase output");
    }

    function test_PeggedSwap_RoundingProtection_ExactOut() public {
        // Use smaller pool to make rounding effects more visible
        PoolSetup memory setup = PoolSetup({
            balanceA: 1000e18,
            balanceB: 1000e18,
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        uint256 amountOut = 1e15; // 0.001 tokens - small but meaningful

        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(false, signature);

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, amountOut, takerData);

        // Verify swap executed
        assertEq(swappedOut, amountOut);

        // Calculate what input would be without rounding protection
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(
            setup.balanceA, setup.balanceB, setup.x0, setup.y0, setup.linearWidth
        );
        uint256 y1 = setup.balanceB - amountOut;
        uint256 v1 = (y1 * PeggedSwapMath.ONE) / setup.y0;
        uint256 u1 = PeggedSwapMath.solve(v1, setup.linearWidth, targetInvariant);

        // Without protection: regular division (rounds DOWN x1 → rounds DOWN amountIn)
        uint256 x1_vulnerable = (u1 * setup.x0) / PeggedSwapMath.ONE;
        uint256 amountIn_vulnerable = x1_vulnerable - setup.balanceA;

        // With protection: ceilDiv (rounds UP x1 → rounds UP amountIn)
        uint256 x1_protected = Math.ceilDiv(u1 * setup.x0, PeggedSwapMath.ONE);
        uint256 amountIn_protected = x1_protected - setup.balanceA;

        // Actual swap should match the protected (safe) calculation
        assertEq(swappedIn, amountIn_protected, "Swap should use rounding protection");
        // Protected input should be >= vulnerable input (safer for maker)
        assertGe(amountIn_protected, amountIn_vulnerable, "Protection should not decrease input");
    }

    // ========================================
    // NEGATIVE TESTS (REVERTS)
    // ========================================

    function test_PeggedSwap_ZeroBalanceIn_SwapSucceeds() public {
        // Zero balanceIn should work — taker puts tokens into an empty reserve
        PoolSetup memory setup = PoolSetup({
            balanceA: 0,  // Zero balance
            balanceB: 1000e18,
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        (uint256 swappedIn, uint256 swappedOut,) = swapVM.swap(order, tokenA, tokenB, 10e18, takerData);

        assertEq(swappedIn, 10e18, "Should accept all input");
        assertGt(swappedOut, 0, "Should produce output from non-empty reserve");
        assertLe(swappedOut, 1000e18, "Output should not exceed balanceOut");
    }

    function test_PeggedSwap_Revert_ZeroBalanceOut_ExactIn() public {
        // Zero balanceOut with ExactIn should revert (can't extract from empty pool)
        PoolSetup memory setup = PoolSetup({
            balanceA: 1000e18,
            balanceB: 0,  // Zero balance
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        vm.expectRevert(PeggedSwapMath.PeggedSwapMathInvalidInput.selector);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    function test_PeggedSwap_Revert_BothBalancesZero() public {
        // Both balances zero is a degenerate state (invariant=0) — must revert
        PoolSetup memory setup = PoolSetup({
            balanceA: 0,
            balanceB: 0,
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(true, signature);

        vm.prank(taker);
        vm.expectRevert(PeggedSwap.PeggedSwapBothBalancesZero.selector);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    function test_PeggedSwap_Revert_ExcessiveAmountOut() public {
        PoolSetup memory setup = PoolSetup({
            balanceA: 1000e18,
            balanceB: 1000e18,
            x0: 1000e18,
            y0: 1000e18,
            linearWidth: 0.8e27,
            feeInBps: 0
        });

        ISwapVM.Order memory order = _createOrder(setup);
        bytes memory signature = _signOrder(order);
        bytes memory takerData = _makeTakerData(false, signature);

        // Try to swap out more than available
        uint256 excessiveAmount = setup.balanceB + 1;

        vm.prank(taker);
        vm.expectRevert();  // Arithmetic underflow in y1 = y0 - amountOut * rateOut
        swapVM.swap(order, tokenA, tokenB, excessiveAmount, takerData);
    }

    // ========================================
    // PEGGEDSWAPMATH UNIT TESTS
    // ========================================

    function test_PeggedSwapMath_Revert_InvalidInput() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();

        // Create a situation where invariantC < sqrtU + au
        uint256 u = 2e27;  // u = 2.0
        uint256 a = 1e27;  // A = 1.0

        // Calculate minimum valid invariant
        uint256 sqrtU = Math.sqrt(u * PeggedSwapMath.ONE);
        uint256 au = (a * u) / PeggedSwapMath.ONE;
        uint256 minInvariant = sqrtU + au;

        // Use invariant that is too low (below minimum)
        uint256 invalidInvariant = minInvariant - 1;

        vm.expectRevert(PeggedSwapMath.PeggedSwapMathInvalidInput.selector);
        wrapper.solve(u, a, invalidInvariant);
    }

    /// @notice Invariant symmetry: invariant(u, v, a) == invariant(v, u, a)
    function test_PeggedSwapMath_InvariantSymmetry() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();
        uint256 ONE = PeggedSwapMath.ONE;

        // Highly asymmetric pairs
        uint256[5] memory us = [uint256(1), 1e15, 1e24, ONE, 2 * ONE];
        uint256[5] memory vs = [2 * ONE, ONE, 1e15, 1e24, uint256(1)];
        uint256[3] memory as_ = [uint256(0), 0.01e27, 2e27];

        for (uint256 i = 0; i < us.length; i++) {
            for (uint256 j = 0; j < as_.length; j++) {
                uint256 inv_uv = wrapper.computeInvariant(us[i], vs[i], as_[j]);
                uint256 inv_vu = wrapper.computeInvariant(vs[i], us[i], as_[j]);
                assertEq(inv_uv, inv_vu, "Invariant must be symmetric in u,v");
            }
        }
    }

    /// @notice solve(u, a, C) round-trips: compute C from (u,v), solve back, get v' >= v
    ///         Tests highly asymmetric, extra large, and extra small reserves
    function test_PeggedSwapMath_SolveRoundTrip_AsymmetricReserves() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();
        uint256 ONE = PeggedSwapMath.ONE;

        // (u, v) pairs — intentionally extreme and asymmetric
        uint256[2][10] memory pairs = [
            [ONE / 1e18, ONE],           // u tiny, v = 1.0
            [ONE, ONE / 1e18],           // u = 1.0, v tiny
            [ONE / 1e9, ONE / 1e9],      // both very small
            [2 * ONE, 2 * ONE],          // both at 2x equilibrium
            [ONE / 100, 2 * ONE],        // 100:1 asymmetry
            [2 * ONE, ONE / 100],        // 1:100 asymmetry
            [uint256(1), ONE],           // 1 wei vs full
            [ONE, uint256(1)],           // full vs 1 wei
            [ONE / 1e6, ONE / 1e6],      // both micro
            [uint256(1), uint256(1)]     // both 1 wei
        ];

        uint256[4] memory as_ = [uint256(0), 0.01e27, 0.8e27, 2e27];

        for (uint256 i = 0; i < pairs.length; i++) {
            uint256 u = pairs[i][0];
            uint256 v = pairs[i][1];

            for (uint256 j = 0; j < as_.length; j++) {
                uint256 a = as_[j];
                uint256 C = wrapper.computeInvariant(u, v, a);

                // Solve for v given u and C — should give v' such that invariant(u, v', a) <= C
                uint256 vSolved = wrapper.solve(u, a, C);

                // v' should be close to v (rounding may make it slightly smaller to protect maker)
                assertLe(vSolved, v + 1, "Solved v should not significantly exceed original v");

                // Re-compute invariant with solved v — it must not exceed C (maker protection)
                uint256 CSolved = wrapper.computeInvariant(u, vSolved, a);
                assertLe(CSolved, C + 1, "Round-trip invariant must not exceed original (maker safety)");
            }
        }
    }

    /// @notice Test solve with one coordinate at zero — depletion edge
    function test_PeggedSwapMath_Solve_ZeroCoordinate() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();
        uint256 ONE = PeggedSwapMath.ONE;

        uint256[3] memory as_ = [uint256(0), 0.8e27, 2e27];

        for (uint256 j = 0; j < as_.length; j++) {
            uint256 a = as_[j];

            // u=0, v=ONE → C = √0 + √1 + a(0+1) = ONE^(1/2) + a
            uint256 C = wrapper.computeInvariant(0, ONE, a);

            // Solve for v when u=0 — should give back ~ONE
            uint256 vSolved = wrapper.solve(0, a, C);
            assertLe(vSolved, ONE + 1, "v from u=0 should be <= ONE");
            assertGe(vSolved, ONE - 1e9, "v from u=0 should be close to ONE");

            // Solve for v when u is at max (v should be ~0)
            uint256 CFromMax = wrapper.computeInvariant(ONE, 0, a);
            uint256 vFromMax = wrapper.solve(ONE, a, CFromMax);
            assertLe(vFromMax, 1e9, "v should be ~0 when u occupies all invariant");
        }
    }

    /// @notice Extra large reserves: invariantFromReserves with big numbers, verify no overflow
    function test_PeggedSwapMath_InvariantFromReserves_ExtraLarge() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();

        _checkLargeReserves(wrapper, 1e24, 0);
        _checkLargeReserves(wrapper, 1e24, 0.8e27);
        _checkLargeReserves(wrapper, 1e24, 2e27);
        _checkLargeReserves(wrapper, 1e27, 0);
        _checkLargeReserves(wrapper, 1e27, 0.8e27);
        _checkLargeReserves(wrapper, 1e27, 2e27);
        _checkLargeReserves(wrapper, 1e30, 0);
        _checkLargeReserves(wrapper, 1e30, 0.8e27);
        _checkLargeReserves(wrapper, 1e30, 2e27);
    }

    function _checkLargeReserves(PeggedSwapMathWrapper wrapper, uint256 x0, uint256 a) private {
        uint256 C = wrapper.computeInvariantFromReserves(x0, x0, x0, x0, a);
        assertTrue(C > 0, "Invariant at equilibrium must be positive");

        uint256 C2 = wrapper.computeInvariantFromReserves(2 * x0, x0 / 2, x0, x0, a);
        assertTrue(C2 > 0, "Invariant at 2:0.5 must be positive");

        uint256 u = 2 * PeggedSwapMath.ONE; // u = 2.0
        uint256 v = PeggedSwapMath.ONE / 2; // v = 0.5
        uint256 vSolved = wrapper.solve(u, a, C2);
        assertLe(vSolved, v + 1e9, "Large-scale solve should be close to v");
    }

    /// @notice Extra small reserves: 1 wei to a few hundred wei
    function test_PeggedSwapMath_InvariantFromReserves_ExtraSmall() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();

        _checkSmallReserves(wrapper, 1, 0);
        _checkSmallReserves(wrapper, 1, 0.8e27);
        _checkSmallReserves(wrapper, 1, 2e27);
        _checkSmallReserves(wrapper, 10, 0);
        _checkSmallReserves(wrapper, 10, 0.8e27);
        _checkSmallReserves(wrapper, 10, 2e27);
        _checkSmallReserves(wrapper, 100, 0);
        _checkSmallReserves(wrapper, 100, 0.8e27);
        _checkSmallReserves(wrapper, 100, 2e27);
        _checkSmallReserves(wrapper, 1e6, 0);
        _checkSmallReserves(wrapper, 1e6, 0.8e27);
        _checkSmallReserves(wrapper, 1e6, 2e27);
    }

    function _checkSmallReserves(PeggedSwapMathWrapper wrapper, uint256 x, uint256 a) private {
        uint256 x0 = 1000e18;
        uint256 y0 = 1000e18;

        uint256 C = wrapper.computeInvariantFromReserves(x, x, x0, y0, a);
        assertTrue(C > 0, "Invariant with tiny reserves must be positive");

        uint256 u = x * PeggedSwapMath.ONE / x0;
        uint256 vSolved = wrapper.solve(u, a, C);
        uint256 ySolved = vSolved * y0 / PeggedSwapMath.ONE;
        assertLe(ySolved, x + 1, "Tiny reserves: solved y should not exceed original");
    }

    /// @notice Highly asymmetric equilibrium reserves (different x0, y0)
    function test_PeggedSwapMath_AsymmetricEquilibrium() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();

        // e.g., WBTC/USDC pool: x0 = 10e8 (10 BTC), y0 = 400_000e6 (400k USDC)
        _checkAsymmetricEquilibrium(wrapper, 1e8, 1e24, 0.8e27);   // 1:1e16 ratio
        _checkAsymmetricEquilibrium(wrapper, 1e24, 1e8, 0.8e27);   // 1e16:1 ratio
        _checkAsymmetricEquilibrium(wrapper, 1e18, 1e18, 2e27);    // 1:1, high A
    }

    function _checkAsymmetricEquilibrium(PeggedSwapMathWrapper wrapper, uint256 x0, uint256 y0, uint256 a) private {
        uint256 C = wrapper.computeInvariantFromReserves(x0, y0, x0, y0, a);
        assertTrue(C > 0, "Asymmetric equilibrium invariant must be positive");

        // Drain x to 10%, solve for v
        uint256 u_drained = PeggedSwapMath.ONE / 10; // 0.1
        uint256 v_solved = wrapper.solve(u_drained, a, C);
        assertTrue(v_solved > PeggedSwapMath.ONE, "Draining x should push v above 1.0");

        // Drain y to 10%, solve for u
        uint256 v_drained = PeggedSwapMath.ONE / 10;
        uint256 u_solved = wrapper.solve(v_drained, a, C);
        assertTrue(u_solved > PeggedSwapMath.ONE, "Draining y should push u above 1.0");
    }

    /// @notice Monotonicity: increasing u should decrease v (and vice versa) on the same curve
    function test_PeggedSwapMath_SolveMonotonicity() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();
        uint256 ONE = PeggedSwapMath.ONE;

        uint256[3] memory as_ = [uint256(0), 0.8e27, 2e27];

        for (uint256 j = 0; j < as_.length; j++) {
            uint256 a = as_[j];
            // Compute C at equilibrium (u=1, v=1)
            uint256 C = wrapper.computeInvariant(ONE, ONE, a);

            uint256 prevV = type(uint256).max;

            // Walk u from tiny to large — v must strictly decrease (or stay if rounding)
            uint256[8] memory uValues = [
                ONE / 1000,  // 0.001
                ONE / 100,   // 0.01
                ONE / 10,    // 0.1
                ONE / 2,     // 0.5
                ONE,         // 1.0
                ONE + ONE / 2, // 1.5
                ONE * 2 - ONE / 10, // 1.9
                ONE * 2      // 2.0 (near curve limit for C ~ 3.6 at a=0.8)
            ];

            for (uint256 i = 0; i < uValues.length; i++) {
                // Skip values where sqrtU + au > C (beyond curve capacity)
                uint256 sqrtU = Math.sqrt(uValues[i] * ONE);
                uint256 au = a * uValues[i] / ONE;
                if (sqrtU + au >= C) break;

                uint256 vNow = wrapper.solve(uValues[i], a, C);
                assertLe(vNow, prevV, "v must decrease as u increases (monotonicity)");
                prevV = vNow;
            }
        }
    }

    /// @notice A=0 special case: pure square-root curve √u + √v = C
    function test_PeggedSwapMath_PureSqrtCurve() public {
        PeggedSwapMathWrapper wrapper = new PeggedSwapMathWrapper();
        uint256 ONE = PeggedSwapMath.ONE;

        // At equilibrium u=v=ONE: C = 2 * √ONE = 2 * ONE^(1/2)
        uint256 C = wrapper.computeInvariant(ONE, ONE, 0);
        uint256 expectedC = 2 * Math.sqrt(ONE * ONE); // 2 * ONE
        assertEq(C, expectedC, "Pure sqrt: C = 2*sqrt(ONE)");

        // u=0 → v should satisfy √v = C → v = C²/ONE
        uint256 vAtZero = wrapper.solve(0, 0, C);
        uint256 expectedV = C * C / ONE;
        assertEq(vAtZero, expectedV, "Pure sqrt: u=0 should give v = C^2/ONE");

        // Asymmetric: u = ONE/4 → √(ONE/4) = ONE/2 → √v = C - ONE/2 → v = (C-ONE/2)²/ONE
        uint256 uQuarter = ONE / 4;
        uint256 vQuarter = wrapper.solve(uQuarter, 0, C);
        uint256 sqrtUq = Math.sqrt(uQuarter * ONE);
        uint256 expectedVq = (C - sqrtUq) * (C - sqrtUq) / ONE;
        assertEq(vQuarter, expectedVq, "Pure sqrt: analytical solution for u=ONE/4");
    }

    // ========================================
    // ROUND-ROBIN DEPLETION & ROUNDING EXPLOIT TEST
    // ========================================

    /// @notice Performs many round-robin swaps that deplete one reserve to zero,
    ///         then refill via reverse swaps, using small edge-case amounts to stress
    ///         rounding. Verifies maker invariant never decreases (no rounding exploit).
    function test_PeggedSwap_RoundRobin_DepletionAndRoundingExploit() public {
        uint256 poolSize = 1000e18;

        // Test with multiple A values
        uint256[3] memory linearWidths = [uint256(0), 0.8e27, 2e27];

        for (uint256 w = 0; w < linearWidths.length; w++) {
            PoolSetup memory setup = PoolSetup({
                balanceA: poolSize,
                balanceB: poolSize,
                x0: poolSize,
                y0: poolSize,
                linearWidth: linearWidths[w],
                feeInBps: 0
            });

            ISwapVM.Order memory order = _createOrder(setup);
            bytes memory signature = _signOrder(order);
            bytes memory takerDataExactIn = _makeTakerData(true, signature);

            // Track cumulative taker in/out to verify maker never loses
            uint256 takerTotalIn = 0;
            uint256 takerTotalOut = 0;

            // Current virtual balances (mirroring what dynamic balances track)
            uint256 balA = poolSize;
            uint256 balB = poolSize;

            // Phase 1: Progressively drain tokenB with increasingly large swaps A→B
            uint256[] memory drainAmounts = new uint256[](6);
            drainAmounts[0] = 100e18;
            drainAmounts[1] = 200e18;
            drainAmounts[2] = 300e18;
            drainAmounts[3] = 200e18;
            drainAmounts[4] = 100e18;
            drainAmounts[5] = 50e18;

            for (uint256 i = 0; i < drainAmounts.length; i++) {
                vm.prank(taker);
                (uint256 amIn, uint256 amOut,) = swapVM.swap(
                    order, tokenA, tokenB, drainAmounts[i], takerDataExactIn
                );
                takerTotalIn += amIn;
                takerTotalOut += amOut;
                balA += amIn;
                balB -= amOut;

                // Verify invariant never decreases (maker protected)
                if (balA > 0 && balB > 0) {
                    uint256 invAfter = PeggedSwapMath.invariantFromReserves(
                        balA, balB, setup.x0, setup.y0, setup.linearWidth
                    );
                    uint256 invInit = PeggedSwapMath.invariantFromReserves(
                        poolSize, poolSize, setup.x0, setup.y0, setup.linearWidth
                    );
                    assertGe(invAfter, invInit - 1, "Invariant must not decrease (drain phase)");
                }
            }

            // Phase 2: Small edge-case swaps A→B near depletion to stress rounding
            uint256[] memory edgeAmounts = new uint256[](8);
            edgeAmounts[0] = 1;           // 1 wei
            edgeAmounts[1] = 7;           // prime
            edgeAmounts[2] = 13;          // prime
            edgeAmounts[3] = 100;         // 100 wei
            edgeAmounts[4] = 1337;        // odd
            edgeAmounts[5] = 1e9;         // 1 gwei
            edgeAmounts[6] = 1e12;        // small
            edgeAmounts[7] = 1e15;        // 0.001 token

            for (uint256 i = 0; i < edgeAmounts.length; i++) {
                if (balB == 0) break; // Already fully depleted

                try swapVM.asView().quote(
                    order, tokenA, tokenB, edgeAmounts[i], takerDataExactIn
                ) returns (uint256, uint256 qOut, bytes32) {
                    if (qOut == 0) continue; // Skip dust that produces zero output

                    vm.prank(taker);
                    (uint256 amIn, uint256 amOut,) = swapVM.swap(
                        order, tokenA, tokenB, edgeAmounts[i], takerDataExactIn
                    );
                    takerTotalIn += amIn;
                    takerTotalOut += amOut;
                    balA += amIn;
                    balB -= amOut;
                } catch {
                    // Expected near full depletion — solve may revert
                }
            }

            // Phase 3: Reverse direction B→A to refill the depleted reserve
            // After depletion, reverse swaps must work
            bytes memory takerDataExactInReverse = _makeTakerData(true, signature);
            uint256[] memory refillAmounts = new uint256[](7);
            refillAmounts[0] = 1;         // 1 wei — extreme edge
            refillAmounts[1] = 100;
            refillAmounts[2] = 1e12;
            refillAmounts[3] = 1e15;
            refillAmounts[4] = 10e18;
            refillAmounts[5] = 50e18;
            refillAmounts[6] = 100e18;

            for (uint256 i = 0; i < refillAmounts.length; i++) {
                try swapVM.asView().quote(
                    order, tokenB, tokenA, refillAmounts[i], takerDataExactInReverse
                ) returns (uint256, uint256 qOut, bytes32) {
                    if (qOut == 0) continue;

                    vm.prank(taker);
                    (uint256 amIn, uint256 amOut,) = swapVM.swap(
                        order, tokenB, tokenA, refillAmounts[i], takerDataExactInReverse
                    );
                    // For B→A swaps: taker puts B in, gets A out
                    // From the pool's perspective: balB increases, balA decreases
                    takerTotalIn += amOut; // taker received A (=amOut), previously gave A as input
                    takerTotalOut += amIn; // taker gave B (=amIn), previously received B as output
                    balB += amIn;
                    balA -= amOut;

                    // Verify invariant after refill
                    if (balA > 0 && balB > 0) {
                        uint256 invAfter = PeggedSwapMath.invariantFromReserves(
                            balA, balB, setup.x0, setup.y0, setup.linearWidth
                        );
                        uint256 invInit = PeggedSwapMath.invariantFromReserves(
                            poolSize, poolSize, setup.x0, setup.y0, setup.linearWidth
                        );
                        assertGe(invAfter, invInit - 1, "Invariant must not decrease (refill phase)");
                    }
                } catch {
                    // May revert for very small amounts near edge
                }
            }

            // Phase 4: More edge-case swaps in both directions with tiny amounts
            for (uint256 round = 0; round < 5; round++) {
                // Small A→B
                uint256 smallAmtAB = (round + 1) * 3 + 1; // 4, 7, 10, 13, 16 wei
                try swapVM.asView().quote(
                    order, tokenA, tokenB, smallAmtAB, takerDataExactIn
                ) returns (uint256, uint256 qOut, bytes32) {
                    if (qOut > 0) {
                        vm.prank(taker);
                        (uint256 amIn, uint256 amOut,) = swapVM.swap(
                            order, tokenA, tokenB, smallAmtAB, takerDataExactIn
                        );
                        balA += amIn;
                        balB -= amOut;
                    }
                } catch {}

                // Small B→A
                uint256 smallAmtBA = (round + 1) * 5 + 2; // 7, 12, 17, 22, 27 wei
                try swapVM.asView().quote(
                    order, tokenB, tokenA, smallAmtBA, takerDataExactInReverse
                ) returns (uint256, uint256 qOut, bytes32) {
                    if (qOut > 0) {
                        vm.prank(taker);
                        (uint256 amIn, uint256 amOut,) = swapVM.swap(
                            order, tokenB, tokenA, smallAmtBA, takerDataExactInReverse
                        );
                        balB += amIn;
                        balA -= amOut;
                    }
                } catch {}
            }

            // Final invariant check: pool should be at least as good as initial
            if (balA > 0 && balB > 0) {
                uint256 invFinal = PeggedSwapMath.invariantFromReserves(
                    balA, balB, setup.x0, setup.y0, setup.linearWidth
                );
                uint256 invInit = PeggedSwapMath.invariantFromReserves(
                    poolSize, poolSize, setup.x0, setup.y0, setup.linearWidth
                );
                assertGe(invFinal, invInit - 1, "Final invariant must not decrease");
            }
        }
    }
}
