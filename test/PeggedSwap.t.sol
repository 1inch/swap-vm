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

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

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

    function test_PeggedSwap_Revert_ZeroBalanceIn() public {
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
        vm.expectRevert(
            abi.encodeWithSelector(
                PeggedSwap.PeggedSwapRequiresBothBalancesNonZero.selector,
                0,
                setup.balanceB
            )
        );
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    function test_PeggedSwap_Revert_ZeroBalanceOut() public {
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
        vm.expectRevert(
            abi.encodeWithSelector(
                PeggedSwap.PeggedSwapRequiresBothBalancesNonZero.selector,
                setup.balanceA,
                0
            )
        );
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
}
