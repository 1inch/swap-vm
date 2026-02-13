// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import {
    XYCConcentrateStrictAdditive,
    XYCConcentrateStrictAdditiveArgsBuilder
} from "../src/instructions/XYCConcentrateStrictAdditive.sol";
import {
    XYCSwapStrictAdditive,
    XYCSwapStrictAdditiveArgsBuilder
} from "../src/instructions/XYCSwapStrictAdditive.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";


contract ConcentrateStrictAdditiveTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 1_000_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000_000e18);

        // Approve SwapVM to spend tokens by maker
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        // Approve SwapVM to spend tokens by taker
        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // TYPES
    // ========================================

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint32 alpha;            // e.g. 997_000_000 for ~0.3% fee equivalent
        uint256 priceBoundA;     // for computing concentration deltas
        uint256 priceBoundB;     // for computing concentration deltas
    }

    struct TakerSetup {
        bool isExactIn;
    }

    // ========================================
    // HELPERS
    // ========================================

    function _createOrder(
        MakerSetup memory setup
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Compute correct deltas for x^α·y=K curve (not x·y=k approximation)
        (uint256 deltaA, uint256 deltaB) =
            XYCConcentrateStrictAdditiveArgsBuilder.computeDeltas(
                setup.balanceA, setup.balanceB, 1e18, setup.priceBoundA, setup.priceBoundB, setup.alpha
            );

        Program memory program = ProgramBuilder.init(_opcodes());
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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
                program.build(XYCConcentrateStrictAdditive._xycConcentrateStrictAdditive2D,
                    XYCConcentrateStrictAdditiveArgsBuilder.build2D(tokenA, tokenB, deltaA, deltaB)
                ),
                program.build(XYCSwapStrictAdditive._xycSwapStrictAdditiveXD,
                    XYCSwapStrictAdditiveArgsBuilder.build(setup.alpha)
                )
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _quotingTakerData(TakerSetup memory takerSetup) internal view returns (bytes memory takerData) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: takerSetup.isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
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

    function _swappingTakerData(bytes memory takerData, bytes memory signature) internal view returns (bytes memory) {
        bool isExactIn = (uint16(bytes2(takerData)) & 0x0001) != 0;

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
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
    }

    function _buildSwapTakerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
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
    }

    // ========================================
    // TESTS: Basic ExactOut quote/swap consistency
    // ========================================

    function test_QuoteAndSwapExactOutAmountsMatches() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,      // ~0.3% fee (equivalent to 0.003e9 flat fee)
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Buy all tokenB liquidity
        uint256 amountOut = setup.balanceB;
        (uint256 quoteAmountIn,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, quoteExactOut);
        vm.prank(taker);
        (uint256 swapAmountIn,,) = swapVM.swap(order, tokenA, tokenB, amountOut, swapExactOut);

        assertEq(swapAmountIn, quoteAmountIn, "Quoted amountIn should match swapped amountIn");
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
    }

    // ========================================
    // TESTS: Price range preservation
    // ========================================

    function test_ConcentrateStrictAdditive_KeepsPriceRangeForTokenA() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check quotes before and after buying all tokenA liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = preRate * 1e18 / postRate;
        // Measured: 0.00004% (0.4 ppm) — limited only by Taylor series precision
        assertApproxEqRel(rateChange, setup.priceBoundA, 0.0001e18, "Price range for tokenA should hold within 0.01%");
    }

    function test_ConcentrateStrictAdditive_KeepsPriceRangeForTokenB() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check quotes before and after buying all tokenB liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, setup.balanceB, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = postRate * 1e18 / preRate;
        // Measured: 0.0001% (1 ppm) — limited only by Taylor series precision
        assertApproxEqRel(rateChange, setup.priceBoundB, 0.0001e18, "Price range for tokenB should hold within 0.01%");
    }

    function test_ConcentrateStrictAdditive_KeepsPriceRangeForBothTokensNoFee() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 1_000_000_000,    // alpha=1.0 (no fee, degenerates to x*y=k)
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        // Measured: 0.00004% — α=1.0 degenerates to x*y=k, no dissipative drift
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.0001e18, "No-fee sequential: tokenA should hold within 0.01%");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        // Measured: 0.0001% — α=1.0 means no dissipative effect, sequential is exact
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.0001e18, "No-fee sequential: tokenB should hold within 0.01%");
    }

    function test_ConcentrateStrictAdditive_KeepsPriceRangeForBothTokensWithFee() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,      // ~0.3% fee
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        // Measured: 0.00004% — first direction starts from initial state, deltas are perfect
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.0001e18, "With-fee sequential: tokenA should hold within 0.01%");

        // Compute and compare rate change for tokenB
        // NOTE: tokenB is the SECOND direction after buying ALL tokenA. The pool state
        // has shifted dramatically (dissipative fees changed real balances), but fixed
        // deltas were computed for the initial state. ~1.4% deviation is inherent to
        // any stateless approach under sequential extreme-drain swaps.
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        // Measured: 1.395% — inherent to stateless design under sequential extreme drains
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.015e18, "With-fee sequential: tokenB should hold within 1.5%");
    }

    // ========================================
    // TESTS: Price range stability over multiple round-trips
    // ========================================

    /// @notice Tests price range stability over 100 partial round-trips using ExactIn
    /// @dev With partial swaps (not draining the pool), the stateless concentration
    ///      should preserve the price range with good accuracy.
    /// @dev Note: Extreme pool-draining round-trips cause drift due to the two-curve
    ///      nature (direction-dependent invariants). Partial swaps avoid this issue.
    function test_ConcentrateStrictAdditive_StabilityOverPartialRoundTrips() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);
        bytes memory swapExactIn = _swappingTakerData(_quotingTakerData(TakerSetup({ isExactIn: true })), signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Perform 100 partial round-trips using ExactIn with small balanced amounts
        // Use same nominal amount for both directions (small relative to pool)
        uint256 partialAmount = 10e18;
        for (uint256 i = 0; i < 100; i++) {
            // Swap some B in to get A (B→A, ExactIn)
            vm.prank(taker);
            swapVM.swap(order, tokenB, tokenA, partialAmount, swapExactIn);

            // Swap some A in to get B (A→B, ExactIn)
            vm.prank(taker);
            swapVM.swap(order, tokenA, tokenB, partialAmount, swapExactIn);
        }

        // After 100 partial round-trips, check that price range is still accurate
        // by buying all remaining tokens and checking the boundary price

        // Buy all tokenA
        uint256 balanceTokenA = swapVM.balances(swapVM.hash(order), address(tokenA));
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, balanceTokenA, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change for tokenA
        // Remaining drift comes from: dissipative round-trips shifting real balances,
        // plus the two extreme pool-draining swaps at the end to reach boundary prices.
        // Taylor series error (~10^-14 per swap) is negligible even after 200 swaps.
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        // Measured: 0.182% — mostly from the final extreme drain (first direction)
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.003e18,
            "After 100 partial round-trips: tokenA price range should hold within 0.3%");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        // Measured: 1.581% — dominated by the sequential extreme drain at the end
        // (same mechanism as WithFee sequential tokenB, plus small round-trip drift)
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.018e18,
            "After 100 partial round-trips: tokenB price range should hold within 1.8%");
    }

    // ========================================
    // TESTS: Pool drain resistance
    // ========================================

    /// @notice Attempt to drain pool via 1000 round-trip swaps in each direction
    /// @dev Math: In A→B→A round trip, pool's tokenB is exactly restored (same amount
    ///      subtracted in leg1 and added back in leg2). Pool can only gain tokenA.
    ///      Vice versa for B→A→B trips. The dissipative fee (α<1) ensures every
    ///      round trip costs the attacker. This test verifies no numerical precision
    ///      error (Taylor series in ln/exp) can reverse this property.
    function test_DrainAttempt_1000RoundTrips() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,      // ~0.3% fee
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory swapExactIn = _buildSwapTakerData(true, signature);

        // --- Phase 1: 1000 A→B→A round trips ---
        // Each trip: attacker sends tokenA, gets tokenB, sends it all back for tokenA
        // Expected: pool gains tokenA each trip, tokenB exactly unchanged
        {
            uint256 swapAmount = 1000e18; // 5% of pool A per trip
            int256 bestPnl = type(int256).min;
            int256 totalPnl;
            uint256 profitableTrips;

            for (uint256 i = 0; i < 1000; i++) {
                vm.prank(taker);
                (, uint256 gotB,) = swapVM.swap(order, tokenA, tokenB, swapAmount, swapExactIn);
                vm.prank(taker);
                (, uint256 gotA,) = swapVM.swap(order, tokenB, tokenA, gotB, swapExactIn);

                int256 pnl = int256(gotA) - int256(swapAmount);
                if (pnl > bestPnl) bestPnl = pnl;
                if (pnl > 0) profitableTrips++;
                totalPnl += pnl;
            }

            uint256 midBalA = swapVM.balances(orderHash, tokenA);
            uint256 midBalB = swapVM.balances(orderHash, tokenB);

            emit log_string("=== Phase 1: 1000 A->B->A round trips (swap=1000e18) ===");
            emit log_named_int("Best single-trip PnL (attacker)", bestPnl);
            emit log_named_int("Total attacker PnL (negative=pool wins)", totalPnl);
            emit log_named_uint("Profitable trips (should be 0)", profitableTrips);
            emit log_named_uint("Pool A: initial", setup.balanceA);
            emit log_named_uint("Pool A: after phase 1", midBalA);
            emit log_named_uint("Pool A gain", midBalA - setup.balanceA);
            emit log_named_uint("Pool B: after phase 1 (should=initial)", midBalB);

            assertLe(bestPnl, 0, "Phase1: no trip should profit the attacker");
            assertEq(profitableTrips, 0, "Phase1: zero profitable trips");
            assertEq(midBalB, setup.balanceB, "Phase1: tokenB must be exactly unchanged");
            assertGe(midBalA, setup.balanceA, "Phase1: pool tokenA must never decrease");
        }

        // --- Phase 2: 1000 B→A→B round trips (on the shifted pool from Phase 1) ---
        // The pool now has extra tokenA from Phase 1 fees. Test the reverse direction.
        {
            uint256 swapAmount = 150e18; // 5% of pool B per trip
            int256 bestPnl = type(int256).min;
            int256 totalPnl;
            uint256 profitableTrips;
            uint256 preBalA = swapVM.balances(orderHash, tokenA);
            uint256 preBalB = swapVM.balances(orderHash, tokenB);

            for (uint256 i = 0; i < 1000; i++) {
                vm.prank(taker);
                (, uint256 gotA,) = swapVM.swap(order, tokenB, tokenA, swapAmount, swapExactIn);
                vm.prank(taker);
                (, uint256 gotB,) = swapVM.swap(order, tokenA, tokenB, gotA, swapExactIn);

                int256 pnl = int256(gotB) - int256(swapAmount);
                if (pnl > bestPnl) bestPnl = pnl;
                if (pnl > 0) profitableTrips++;
                totalPnl += pnl;
            }

            uint256 finalBalA = swapVM.balances(orderHash, tokenA);
            uint256 finalBalB = swapVM.balances(orderHash, tokenB);

            emit log_string("=== Phase 2: 1000 B->A->B round trips (swap=150e18) ===");
            emit log_named_int("Best single-trip PnL (attacker)", bestPnl);
            emit log_named_int("Total attacker PnL (negative=pool wins)", totalPnl);
            emit log_named_uint("Profitable trips (should be 0)", profitableTrips);
            emit log_named_uint("Pool B: before phase 2", preBalB);
            emit log_named_uint("Pool B: after phase 2", finalBalB);
            emit log_named_uint("Pool B gain", finalBalB - preBalB);
            emit log_named_uint("Pool A: after phase 2 (should=phase1)", finalBalA);

            assertLe(bestPnl, 0, "Phase2: no trip should profit the attacker");
            assertEq(profitableTrips, 0, "Phase2: zero profitable trips");
            assertEq(finalBalA, preBalA, "Phase2: tokenA must be exactly unchanged");
            assertGe(finalBalB, preBalB, "Phase2: pool tokenB must never decrease");
        }
    }

    /// @notice Sweep alpha (fee) values to determine the safe fee bound
    /// @dev Tests from α=0.999999 (0.0001% fee) to α=0.95 (5% fee)
    ///      Each alpha: 200 A→B→A + 200 B→A→B round trips
    /// @dev Theoretical analysis: the Taylor series error in ln/exp is ~10^{-14} relative,
    ///      while the minimum fee per swap at α=0.999999 is ~10^{-6} relative.
    ///      So even the smallest testable fee is ~10^8x larger than numerical error.
    ///      The uint32 alpha resolution (1/10^9) provides an even stronger guarantee.
    function test_DrainAttempt_SafeFeeBound() public {
        uint32[7] memory alphas = [
            uint32(999_999_000), // α=0.999999 (~0.0001% fee)
            uint32(999_990_000), // α=0.99999  (~0.001% fee)
            uint32(999_900_000), // α=0.9999   (~0.01% fee)
            uint32(999_000_000), // α=0.999    (~0.1% fee)
            uint32(997_000_000), // α=0.997    (~0.3% fee)
            uint32(990_000_000), // α=0.99     (~1% fee)
            uint32(950_000_000)  // α=0.95     (~5% fee)
        ];

        uint256 totalUnsafe;

        for (uint256 a = 0; a < alphas.length; a++) {
            uint256 snap = vm.snapshot();

            MakerSetup memory setup = MakerSetup({
                balanceA: 20000e18,
                balanceB: 3000e18,
                alpha: alphas[a],
                priceBoundA: 0.01e18,
                priceBoundB: 25e18
            });
            (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
            bytes memory swapExactIn = _buildSwapTakerData(true, signature);

            int256 bestPnlAB = type(int256).min;
            int256 bestPnlBA = type(int256).min;
            uint256 profitAB;
            uint256 profitBA;

            // 200 A→B→A round trips
            for (uint256 i = 0; i < 200; i++) {
                vm.prank(taker);
                (, uint256 gotB,) = swapVM.swap(order, tokenA, tokenB, 1000e18, swapExactIn);
                vm.prank(taker);
                (, uint256 gotA,) = swapVM.swap(order, tokenB, tokenA, gotB, swapExactIn);

                int256 pnl = int256(gotA) - 1000e18;
                if (pnl > bestPnlAB) bestPnlAB = pnl;
                if (pnl > 0) profitAB++;
            }

            // 200 B→A→B round trips (on shifted pool)
            for (uint256 i = 0; i < 200; i++) {
                vm.prank(taker);
                (, uint256 gotA,) = swapVM.swap(order, tokenB, tokenA, 150e18, swapExactIn);
                vm.prank(taker);
                (, uint256 gotB,) = swapVM.swap(order, tokenA, tokenB, gotA, swapExactIn);

                int256 pnl = int256(gotB) - 150e18;
                if (pnl > bestPnlBA) bestPnlBA = pnl;
                if (pnl > 0) profitBA++;
            }

            bool safe = (profitAB == 0 && profitBA == 0);

            emit log_string("---");
            emit log_named_uint("Alpha", alphas[a]);
            emit log_named_int("Best A->B->A PnL", bestPnlAB);
            emit log_named_int("Best B->A->B PnL", bestPnlBA);
            emit log_named_uint("Profitable A->B->A", profitAB);
            emit log_named_uint("Profitable B->A->B", profitBA);
            emit log_named_string("SAFE", safe ? "YES" : "NO");

            if (!safe) totalUnsafe++;

            vm.revertTo(snap);
        }

        assertEq(totalUnsafe, 0, "All tested alpha values should be safe against drain");
    }

    /// @notice Test drain resistance across different swap sizes
    /// @dev From tiny (0.01 tokens) to huge (50% of pool), 200 round trips each
    /// @dev Tiny swaps stress the rounding behavior (floor division protects maker),
    ///      large swaps stress the Taylor series over wide ratio ranges.
    function test_DrainAttempt_VaryingSwapSizes() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 20000e18,
            balanceB: 3000e18,
            alpha: 997_000_000,
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });

        uint256[5] memory swapSizes = [
            uint256(0.01e18),    // tiny: 0.00005% of pool
            uint256(1e18),       // small: 0.005% of pool
            uint256(100e18),     // medium: 0.5% of pool
            uint256(1000e18),    // large: 5% of pool
            uint256(10000e18)    // huge: 50% of pool
        ];

        for (uint256 s = 0; s < swapSizes.length; s++) {
            uint256 snap = vm.snapshot();

            (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
            bytes memory swapExactIn = _buildSwapTakerData(true, signature);

            int256 bestPnl = type(int256).min;
            uint256 profitableTrips;

            for (uint256 i = 0; i < 200; i++) {
                vm.prank(taker);
                (, uint256 gotB,) = swapVM.swap(order, tokenA, tokenB, swapSizes[s], swapExactIn);
                vm.prank(taker);
                (, uint256 gotA,) = swapVM.swap(order, tokenB, tokenA, gotB, swapExactIn);

                int256 pnl = int256(gotA) - int256(swapSizes[s]);
                if (pnl > bestPnl) bestPnl = pnl;
                if (pnl > 0) profitableTrips++;
            }

            emit log_string("---");
            emit log_named_uint("Swap size", swapSizes[s]);
            emit log_named_int("Best trip PnL", bestPnl);
            emit log_named_uint("Profitable trips", profitableTrips);

            assertEq(profitableTrips, 0, "No profitable trips at any swap size");

            vm.revertTo(snap);
        }
    }
}
