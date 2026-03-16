// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright (c) 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

contract XYCConcentratePnLTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    uint256 constant ONE     = 1e18;
    uint32  constant FEE_BPS = 3_000_000; // 0.3%
    uint256 constant ROUNDS  = 200;

    // ── Range A: P in [0.04, 4], sqrtP in [0.2, 2] ──────────────────────────
    uint256 constant SQRT_P_MIN_A  = 200_000_000_000_000_000;   // sqrt(0.04·1e36) = 0.2e18
    uint256 constant SQRT_P_MAX_A  = 2_000_000_000_000_000_000; // sqrt(4·1e36)    = 2.0e18

    // Off-center spots inside Range A
    uint256 constant SQRT_P_SPOT_LOW  = 500_000_000_000_000_000;   // sqrt(0.25·1e36) = 0.5e18  (P=0.25, near lower)
    uint256 constant SQRT_P_SPOT_HIGH = 1_500_000_000_000_000_000; // sqrt(2.25·1e36) = 1.5e18  (P=2.25, near upper)

    // ── Range B: P in [16, 100], sqrtP in [4, 10] (high price ratio) ─────────
    uint256 constant SQRT_P_MIN_B  = 4_000_000_000_000_000_000;  // sqrt(16·1e36)  = 4e18
    uint256 constant SQRT_P_MAX_B  = 10_000_000_000_000_000_000; // sqrt(100·1e36) = 10e18
    uint256 constant SQRT_P_SPOT_B = 5_000_000_000_000_000_000;  // sqrt(25·1e36)  = 5e18  (P=25)

    // ── Range C: asymmetric [0.50, 1.05] at P_spot = 1.0 ─────────────────────
    // Used to show that even with a symmetric spot an asymmetric range forces
    // the maker to use computeLiquidityFromAmounts (bLt != bGt).
    uint256 constant SQRT_P_MIN_C  = 707_106_781_186_547_524;    // sqrt(0.50·1e36)
    uint256 constant SQRT_P_MAX_C  = 1_024_695_076_595_959_695;  // sqrt(1.05·1e36)
    uint256 constant SQRT_P_SPOT_C = 1_000_000_000_000_000_000;  // sqrt(1.00·1e36) = 1e18

    // Round-trip counts and fee rate for Range-C scenario (original PnL test parameters)
    uint32  constant FEE_BPS_C     = 500_000;  // 0.05%
    uint256 constant ROUNDS_C      = 500;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenLt; // lower address
    address public tokenGt; // higher address
    address public maker;
    uint256 public makerPK;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPK = 0x1234;
        maker   = vm.addr(makerPK);
        swapVM  = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Ensure tokenLt < tokenGt (required by XYCConcentrate math)
        TokenMock tA = new TokenMock("TokenA", "A");
        TokenMock tB = new TokenMock("TokenB", "B");
        (tokenLt, tokenGt) = address(tA) < address(tB)
            ? (address(tA), address(tB))
            : (address(tB), address(tA));

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? maker : taker;
            TokenMock(tokenLt).mint(who, 1_000_000_000e18);
            TokenMock(tokenGt).mint(who, 1_000_000_000e18);
            vm.prank(who);
            TokenMock(tokenLt).approve(address(swapVM), type(uint256).max);
            vm.prank(who);
            TokenMock(tokenGt).approve(address(swapVM), type(uint256).max);
        }
    }

    function _createOrder(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (ISwapVM.Order memory order, bytes memory sig) {
        Program memory p = ProgramBuilder.init(_opcodes());
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
                p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([tokenLt, tokenGt]),
                    dynamic([bLt, bGt])
                )),
                p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                ),
                p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(FEE_BPS)),
                p.build(XYCSwap._xycSwapXD)
            )
        }));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        sig = abi.encodePacked(r, s, v);
    }

    function _td(bytes memory sig, bool isExactIn) internal view returns (bytes memory) {
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
            signature: sig
        }));
    }

    struct SpotSetup {
        uint256 sqrtPspot;
        uint256 sqrtPmin;
        uint256 sqrtPmax;
        string label;
    }

    /// @notice ExactIn: quote vs swap for a single direction. Returns amountOut for exactOut follow-up.
    function _checkExactIn(
        ISwapVM.Order memory order,
        bytes memory sig,
        uint256 amount,
        string memory label
    ) internal returns (uint256 amountOut) {
        bytes memory td = _td(sig, true);
        (uint256 qIn, uint256 qOut,) = swapVM.asView().quote(order, tokenLt, tokenGt, amount, td);
        uint256 snap = vm.snapshot();
        vm.prank(taker);
        (uint256 sIn, uint256 sOut,) = swapVM.swap(order, tokenLt, tokenGt, amount, td);
        vm.revertTo(snap);
        assertEq(sIn,  qIn,  string.concat(label, ": exactIn amountIn"));
        assertEq(sOut, qOut, string.concat(label, ": exactIn amountOut"));
        amountOut = qOut;
    }

    /// @notice ExactOut: quote vs swap for a given output amount.
    function _checkExactOut(
        ISwapVM.Order memory order,
        bytes memory sig,
        uint256 exactOutAmount,
        string memory label
    ) internal {
        bytes memory td = _td(sig, false);
        (uint256 qIn,  uint256 qOut,) = swapVM.asView().quote(order, tokenLt, tokenGt, exactOutAmount, td);
        uint256 snap = vm.snapshot();
        vm.prank(taker);
        (uint256 sIn, uint256 sOut,) = swapVM.swap(order, tokenLt, tokenGt, exactOutAmount, td);
        vm.revertTo(snap);
        assertEq(sIn,  qIn,  string.concat(label, ": exactOut amountIn"));
        assertEq(sOut, qOut, string.concat(label, ": exactOut amountOut"));
    }

    /// @notice quote() and swap() must return identical amounts for an off-center pool.
    function _assertQuoteEqualsSwap(SpotSetup memory s) internal {
        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            100_000e18, 100_000e18, s.sqrtPspot, s.sqrtPmin, s.sqrtPmax
        );
        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(bLt, bGt, s.sqrtPmin, s.sqrtPmax);
        uint256 amtOut = _checkExactIn(order, sig, bLt / 10, s.label);
        _checkExactOut(order, sig, amtOut, s.label);
    }

    function test_QuoteEqualsSwap_SpotBelow1() public {
        _assertQuoteEqualsSwap(SpotSetup({
            sqrtPspot: SQRT_P_SPOT_LOW,
            sqrtPmin:  SQRT_P_MIN_A,
            sqrtPmax:  SQRT_P_MAX_A,
            label:     "SpotBelow1"
        }));
    }

    function test_QuoteEqualsSwap_SpotAbove1() public {
        _assertQuoteEqualsSwap(SpotSetup({
            sqrtPspot: SQRT_P_SPOT_HIGH,
            sqrtPmin:  SQRT_P_MIN_A,
            sqrtPmax:  SQRT_P_MAX_A,
            label:     "SpotAbove1"
        }));
    }

    function test_QuoteEqualsSwap_HighPriceRatio() public {
        _assertQuoteEqualsSwap(SpotSetup({
            sqrtPspot: SQRT_P_SPOT_B,
            sqrtPmin:  SQRT_P_MIN_B,
            sqrtPmax:  SQRT_P_MAX_B,
            label:     "HighPriceRatio"
        }));
    }

    /// @notice Helper: get the pre-exhaustion rate for Lt→Gt swaps (Gt out per Lt in).
    function _preExhaustRate(
        ISwapVM.Order memory order,
        bytes memory tdIn
    ) internal view returns (uint256 rate) {
        (, uint256 preOut,) = swapVM.asView().quote(order, tokenLt, tokenGt, 1e18, tdIn);
        rate = preOut; // Gt per 1e18 Lt (denominator cancels)
    }

    /// @notice Helper: get the post-exhaustion rate for Lt→Gt swaps.
    function _postExhaustRate(
        ISwapVM.Order memory order,
        bytes memory tdIn
    ) internal view returns (uint256 rate) {
        (, uint256 postOut,) = swapVM.asView().quote(order, tokenLt, tokenGt, 1e18, tdIn);
        rate = postOut;
    }

    /// @notice Price bounds must hold regardless of initial spot price.
    ///
    ///         Buying all Gt (exact-out) moves the pool price DOWN toward sqrtPmin.
    ///         After exhaustion: postRate ≈ P_min (few Gt per Lt).
    ///         The ratio preRate/postRate ≈ P_spot / P_min  (within 2%).
    function _assertPriceBoundsWithOffCenterSpot(
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        string memory label
    ) internal {
        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            100_000e18, 100_000e18, sqrtPspot, sqrtPmin, sqrtPmax
        );
        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(bLt, bGt, sqrtPmin, sqrtPmax);

        uint256 preRate = _preExhaustRate(order, _td(sig, true));

        // Exhaust all Gt (buying moves price toward sqrtPmin)
        vm.prank(taker);
        swapVM.swap(order, tokenLt, tokenGt, bGt, _td(sig, false));
        assertEq(swapVM.balances(swapVM.hash(order), tokenGt), 0,
            string.concat(label, ": all Gt should be bought out"));

        uint256 postRate = _postExhaustRate(order, _td(sig, true));
        // preRate / postRate ≈ P_spot / P_min = sqrtPspot² / sqrtPmin² (both in 1e18 scale)
        uint256 pSpot        = sqrtPspot * sqrtPspot / ONE;   // normalised to 1e18 denom
        uint256 pMin         = sqrtPmin  * sqrtPmin  / ONE;
        uint256 expectedRatio = Math.mulDiv(pSpot, ONE, pMin);
        uint256 actualRatio   = preRate * ONE / postRate;
        assertApproxEqRel(actualRatio, expectedRatio, 0.02e18,
            string.concat(label, ": P_spot/P_min rate ratio incorrect after Gt exhaustion"));
    }

    function test_PriceBounds_SpotBelow1() public {
        _assertPriceBoundsWithOffCenterSpot(SQRT_P_SPOT_LOW, SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotBelow1");
    }

    function test_PriceBounds_SpotAbove1() public {
        _assertPriceBoundsWithOffCenterSpot(SQRT_P_SPOT_HIGH, SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotAbove1");
    }

    // =========================================================================
    // Maker P&L tests — CORRECT initialization earns fees, WRONG initialization loses
    // =========================================================================

    /// @notice Run value-balanced round-trips.
    ///         swapSizeLt and swapSizeGt have equal economic value at the pool's spot price,
    ///         so neither token is exhausted over many rounds.
    function _runBalancedRoundTrips(
        ISwapVM.Order memory order,
        bytes memory td,
        uint256 swapSizeLt,
        uint256 swapSizeGt
    ) internal {
        vm.startPrank(taker);
        for (uint256 i = 0; i < ROUNDS; i++) {
            swapVM.swap(order, tokenLt, tokenGt, swapSizeLt, td);
            swapVM.swap(order, tokenGt, tokenLt, swapSizeGt, td);
        }
        vm.stopPrank();
    }

    /// @notice CORRECT initialization: maker derives balances from computeLiquidityFromAmounts.
    ///         After value-balanced round-trips, the pool's LIQUIDITY L must grow (fees collected).
    ///
    ///         Why liquidity, not raw TVL?
    ///         For P_spot ≠ 1, bLt and bGt have different token values. Raw token count (bLt+bGt)
    ///         changes with pool price even with zero economic gain. Liquidity L is the invariant
    ///         that only increases with fee collection and is the correct maker-earnings metric.
    function _assertMakerEarnsWithCorrectInit(
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        string memory label
    ) internal {
        uint256 avail = 100_000e18;
        (uint256 initialL, uint256 bLt, uint256 bGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(avail, avail, sqrtPspot, sqrtPmin, sqrtPmax);

        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(bLt, bGt, sqrtPmin, sqrtPmax);

        // Value-balanced swap sizes: each leg has equal economic value at P_spot.
        // P_spot in 1e18 units: P = sqrtPspot² / 1e18.
        // swapSizeLt * P = swapSizeGt  →  equal economic value each direction.
        uint256 pSpot = sqrtPspot * sqrtPspot / ONE;
        // Constrain to 1/50 of the smaller-value side
        uint256 bLtInGt  = Math.mulDiv(bLt, pSpot, ONE);   // bLt value expressed in Gt
        uint256 smallSide = bLtInGt < bGt ? bLtInGt : bGt; // smaller side in Gt units
        uint256 swapSizeGt = smallSide / 50;
        uint256 swapSizeLt = Math.mulDiv(swapSizeGt, ONE, pSpot);
        if (swapSizeLt < 1e14) { swapSizeLt = 1e14; swapSizeGt = Math.mulDiv(1e14, pSpot, ONE); }

        _runBalancedRoundTrips(order, _td(sig, true), swapSizeLt, swapSizeGt);

        bytes32 h = swapVM.hash(order);
        (uint256 finalL,) = XYCConcentrateArgsBuilder.computeLiquidityAndPrice(
            swapVM.balances(h, tokenLt),
            swapVM.balances(h, tokenGt),
            sqrtPmin,
            sqrtPmax
        );
        assertTrue(finalL >= initialL,
            string.concat(label, " [correct]: liquidity must grow after fee-earning round-trips"));
    }

    /// @notice WRONG initialization: maker uses equal bLt=bGt instead of correct ratio.
    ///         Naive equal-size round-trips drain raw TVL because the pool's implied price
    ///         differs from the intended spot, so each round-trip swaps asymmetric value.
    function _assertMakerLosesWithWrongInit(
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        string memory label
    ) internal {
        uint256 avail = 100_000e18;
        uint256 bLt   = avail;
        uint256 bGt   = avail;
        uint256 initialTVL = bLt + bGt;

        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(bLt, bGt, sqrtPmin, sqrtPmax);

        uint256 swapSize = avail / 50; // 2 000e18
        bytes memory td  = _td(sig, true);
        vm.startPrank(taker);
        for (uint256 i = 0; i < ROUNDS; i++) {
            swapVM.swap(order, tokenLt, tokenGt, swapSize, td);
            swapVM.swap(order, tokenGt, tokenLt, swapSize, td);
        }
        vm.stopPrank();

        bytes32 h    = swapVM.hash(order);
        uint256 finalTVL = swapVM.balances(h, tokenLt) + swapVM.balances(h, tokenGt);
        int256  pnl  = int256(finalTVL) - int256(initialTVL);
        assertTrue(pnl < 0,
            string.concat(label, " [wrong]: raw TVL must fall when balances mismatch spot"));
    }

    function test_MakerEarns_CorrectBalances_SpotBelow1() public {
        _assertMakerEarnsWithCorrectInit(SQRT_P_SPOT_LOW, SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotBelow1");
    }

    function test_MakerLoses_WrongBalances_SpotBelow1() public {
        _assertMakerLosesWithWrongInit(SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotBelow1");
    }

    function test_MakerEarns_CorrectBalances_SpotAbove1() public {
        _assertMakerEarnsWithCorrectInit(SQRT_P_SPOT_HIGH, SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotAbove1");
    }

    function test_MakerLoses_WrongBalances_SpotAbove1() public {
        _assertMakerLosesWithWrongInit(SQRT_P_MIN_A, SQRT_P_MAX_A, "SpotAbove1");
    }

    function test_MakerEarns_CorrectBalances_HighPriceRatio() public {
        _assertMakerEarnsWithCorrectInit(SQRT_P_SPOT_B, SQRT_P_MIN_B, SQRT_P_MAX_B, "HighPriceRatio");
    }

    // =========================================================================
    // Range C: asymmetric range [0.50, 1.05] with  P_spot = 1.0
    //
    // Demonstrates that even when the spot price equals 1.0 an asymmetric range
    // forces the maker to use computeLiquidityFromAmounts (bLt != bGt).
    // =========================================================================

    /// @dev Same as _createOrder but with a configurable fee (for Range-C scenario).
    function _createOrderC(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (ISwapVM.Order memory order, bytes memory sig) {
        Program memory p = ProgramBuilder.init(_opcodes());
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
                p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([tokenLt, tokenGt]),
                    dynamic([bLt, bGt])
                )),
                p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                ),
                p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(FEE_BPS_C)),
                p.build(XYCSwap._xycSwapXD)
            )
        }));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Uniform-size round-trips (same token amount both directions).
    ///      Appropriate when P_spot = 1.0 so both tokens have equal value.
    function _runUniformRoundTrips(
        ISwapVM.Order memory order,
        bytes memory td,
        uint256 swapSize,
        uint256 rounds
    ) internal {
        vm.startPrank(taker);
        for (uint256 i = 0; i < rounds; i++) {
            swapVM.swap(order, tokenLt, tokenGt, swapSize, td);
            swapVM.swap(order, tokenGt, tokenLt, swapSize, td);
        }
        vm.stopPrank();
    }

    /// @notice Correct balances for asymmetric range [0.50, 1.05] at P_spot = 1.0.
    ///         computeLiquidityFromAmounts returns bLt ~= 8 228 and bGt ~= 100 000
    ///         (heavily skewed toward Gt because the range is much wider below spot).
    ///         After 500 symmetric round-trips the pool's TVL grows (fee income > 0).
    function test_AsymmetricRange_CorrectInit_MakerEarns() public {
        uint256 availableLt = 100_000e18;
        uint256 availableGt = 100_000e18;

        (, uint256 actualLt, uint256 actualGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            availableLt, availableGt, SQRT_P_SPOT_C, SQRT_P_MIN_C, SQRT_P_MAX_C
        );
        uint256 initialTVL = actualLt + actualGt;

        // Verify the implied spot equals 1.0 exactly
        (, uint256 impliedSqrtP) =
            XYCConcentrateArgsBuilder.computeLiquidityAndPrice(actualLt, actualGt, SQRT_P_MIN_C, SQRT_P_MAX_C);
        assertApproxEqRel(impliedSqrtP, ONE, 1e15,
            "AsymmetricRange correct: implied sqrtPspot must be ~1e18");

        (ISwapVM.Order memory order, bytes memory sig) = _createOrderC(actualLt, actualGt, SQRT_P_MIN_C, SQRT_P_MAX_C);
        bytes32 h = swapVM.hash(order);

        uint256 swapSize = actualLt / 50;
        if (swapSize < 1e15) swapSize = 1e15;

        _runUniformRoundTrips(order, _td(sig, true), swapSize, ROUNDS_C);

        uint256 finalTVL = swapVM.balances(h, tokenLt) + swapVM.balances(h, tokenGt);
        assertTrue(int256(finalTVL) >= int256(initialTVL),
            "AsymmetricRange [correct]: TVL must grow after fee-earning round-trips");
    }

    /// @notice Wrong (equal) balances for asymmetric range [0.50, 1.05].
    ///         bLt = bGt = 100 000 implies P_spot ~= 0.766, far from market price 1.0.
    ///         A rational taker exploits every round-trip; structural loss > fee income.
    function test_AsymmetricRange_WrongInit_MakerLoses() public {
        uint256 bLt = 100_000e18;
        uint256 bGt = 100_000e18;
        uint256 initialTVL = bLt + bGt;

        // Confirm the mismatch: implied P_spot != 1.0
        (, uint256 impliedSqrtP) =
            XYCConcentrateArgsBuilder.computeLiquidityAndPrice(bLt, bGt, SQRT_P_MIN_C, SQRT_P_MAX_C);
        // impliedSqrtP ≈ 0.875e18  (P ≈ 0.766), well below 1.0
        assertTrue(impliedSqrtP < ONE,
            "AsymmetricRange wrong: implied sqrtPspot must be < 1 with equal balances");

        (ISwapVM.Order memory order, bytes memory sig) = _createOrderC(bLt, bGt, SQRT_P_MIN_C, SQRT_P_MAX_C);
        bytes32 h = swapVM.hash(order);

        _runUniformRoundTrips(order, _td(sig, true), 1_000e18, ROUNDS_C);

        uint256 finalTVL = swapVM.balances(h, tokenLt) + swapVM.balances(h, tokenGt);
        assertTrue(int256(finalTVL) < int256(initialTVL),
            "AsymmetricRange [wrong]: TVL must fall when balances mismatch range");
    }
}
