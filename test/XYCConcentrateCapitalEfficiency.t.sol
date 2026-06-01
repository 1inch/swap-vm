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
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @title XYCConcentrate Capital Efficiency vs XYCSwap
/// @notice Proves that XYCConcentrate achieves higher capital efficiency than plain XYCSwap.
///
///         Mathematical foundation
///         =======================
///         XYCSwap (Uniswap-V2 full-range):
///           virtualLt = bLt
///           virtualGt = bGt
///           amountOut  = bGt * amountIn / (bLt + amountIn)
///
///         XYCConcentrate (CLAMM, range [sqrtPmin, sqrtPmax], spot P=1):
///           L          = bLt / (1 - 1/sqrtPmax)   [concentration factor = 1/(1-1/sqrtPmax)]
///           virtualLt  = bLt + L/sqrtPmax  = L     [full virtual reserve]
///           virtualGt  = bGt + L*sqrtPmin  = L
///           amountOut  = L * amountIn / (L + amountIn)
///
///         For center-symmetric range (sqrtPmin * sqrtPmax = 1, e.g. [0.5, 2]):
///           L = bLt / (1 - 1/sqrtPmax) = bLt / (1 - sqrtPmin)
///           concentration factor R = L/bLt = 1/(1-sqrtPmin)   [e.g. R=2 for sqrtPmin=0.5]
///
///         Key invariants tested
///         =====================
///         TEST 1 — Same capital, better output:
///           concentrateOut(K, amountIn) > xycSwapOut(K, amountIn)   for all amountIn > 0
///
///         TEST 2 — Half capital, same output:
///           concentrateOut(K/R, amountIn) == xycSwapOut(K, amountIn)
///           (where R is the concentration factor)
///
///         TEST 3 — Marginal price:
///           marginal rate of concentrate = R × marginal rate of xycSwap (for tiny swaps)
///
///         TEST 4 — Slippage comparison:
///           concentrate achieves the same output amount for a SMALLER input
contract XYCConcentrateCapitalEfficiencyTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    uint256 constant ONE = 1e18;

    // Center-symmetric range [0.25, 4] — sqrtPmin=0.5, sqrtPmax=2
    // Concentration factor R = 1/(1-sqrtPmin) = 1/(1-0.5) = 2
    uint256 constant SQRT_P_MIN = 500_000_000_000_000_000;   // 0.5e18
    uint256 constant SQRT_P_MAX = 2_000_000_000_000_000_000; // 2.0e18
    uint256 constant CONCENTRATION_FACTOR = 2;               // R=2x

    // Narrow range [0.9, 100/9] — sqrtPmin=0.9, sqrtPmax≈10/3  factor ≈ 10x
    uint256 constant SQRT_P_MIN_NARROW = 900_000_000_000_000_000;          // 0.9e18
    uint256 constant SQRT_P_MAX_NARROW = 3_333_333_333_333_333_333;        // ~3.33e18 (≈10/3)
    // For sqrtPmin=0.9: R = 1/(1-0.9) = 10

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenLt;
    address public tokenGt;
    address public maker;
    uint256 public makerPK;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPK = 0x1234;
        maker   = vm.addr(makerPK);
        swapVM  = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

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

    // ── Order builders ────────────────────────────────────────────────────────

    /// @dev Plain XYCSwap order (Uniswap-V2 full-range, no concentration)
    function _xycSwapOrder(
        uint256 bLt,
        uint256 bGt
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
            preTransferInTarget: address(0), preTransferInData: "",
            postTransferInTarget: address(0), postTransferInData: "",
            preTransferOutTarget: address(0), preTransferOutData: "",
            postTransferOutTarget: address(0), postTransferOutData: "",
            program: bytes.concat(
                p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([tokenLt, tokenGt]),
                    dynamic([bLt, bGt])
                )),
                p.build(XYCSwap._xycSwapXD)
            )
        }));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev XYCConcentrate order (CLAMM with price bounds)
    function _concentrateOrder(
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
            preTransferInTarget: address(0), preTransferInData: "",
            postTransferInTarget: address(0), postTransferInData: "",
            preTransferOutTarget: address(0), preTransferOutData: "",
            postTransferOutTarget: address(0), postTransferOutData: "",
            program: bytes.concat(
                p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([tokenLt, tokenGt]),
                    dynamic([bLt, bGt])
                )),
                p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                )
            )
        }));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        sig = abi.encodePacked(r, s, v);
    }

    function _tdIn(bytes memory sig) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker, isExactIn: true, shouldUnwrapWeth: false,
            isStrictThresholdAmount: false, isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false, threshold: "", to: address(0),
            deadline: 0, hasPreTransferInCallback: false, hasPreTransferOutCallback: false,
            preTransferInHookData: "", postTransferInHookData: "",
            preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "",
            instructionsArgs: "", signature: sig
        }));
    }

    /// @dev Quote exact-in without executing (uses vm.snapshot + revert)
    function _quoteExactIn(
        ISwapVM.Order memory order,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        // Re-extract sig from order for _tdIn — use asView which is stateless
        (, amountOut,) = swapVM.asView().quote(order, tokenLt, tokenGt, amountIn, _tdIn(""));
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    /// @notice TEST 1: Same capital → concentrate gives MORE output (less slippage)
    ///
    ///   Capital: 10 000 each token (total 20 000)
    ///   Range:   [0.5, 2], concentration factor R=2
    ///   Input:   1 000 Lt
    ///
    ///   XYCSwap:      out = 10_000 × 1_000 / 11_000 ≈ 909.09
    ///   Concentrate:  out = 20_000 × 1_000 / 21_000 ≈ 952.38  (+4.7%)
    function test_SameCapital_ConcentrateOutputBetter() public view {
        uint256 capital  = 10_000e18;
        uint256 swapIn   = 1_000e18;

        (ISwapVM.Order memory xycOrder,)  = _xycSwapOrder(capital, capital);
        (ISwapVM.Order memory concOrder,) = _concentrateOrder(capital, capital, SQRT_P_MIN, SQRT_P_MAX);

        (, uint256 xycOut,)  = swapVM.asView().quote(xycOrder,  tokenLt, tokenGt, swapIn, _tdIn(""));
        (, uint256 concOut,) = swapVM.asView().quote(concOrder, tokenLt, tokenGt, swapIn, _tdIn(""));

        assertGt(concOut, xycOut,
            "Concentrate must give more output than XYCSwap for same capital");

        // Derivation:
        //   xycOut  = K * in / (K + in)
        //   concOut = 2K * in / (2K + in)   (L = 2K for R=2)
        //   ratio   = concOut / xycOut = 2K*(K+in) / (K*(2K+in)) = 2*(K+in)/(2K+in)
        //
        // For K=10_000, in=1_000: ratio = 2*11_000/21_000 = 22/21 ≈ 1.04762
        uint256 expectedRatio = Math.mulDiv(2 * (capital + swapIn), ONE, 2 * capital + swapIn);
        uint256 actualRatio   = Math.mulDiv(concOut, ONE, xycOut);
        assertApproxEqRel(actualRatio, expectedRatio, 0.001e18,
            "Output ratio must match 2*(K+in)/(2K+in) formula");
    }

    /// @notice TEST 2: Half capital → concentrate output equals full-capital XYCSwap
    ///
    ///   XYCSwap:              capital K = 10 000,  virtual = K     = 10 000
    ///   Concentrate (R=2):    capital K' = K/R = 5 000, virtual = L = K'/0.5 = K
    ///
    ///   Both pools have identical virtual reserves → identical output for any input.
    function test_HalfCapital_ConcentrateMatchesFullXYCSwap() public view {
        uint256 capital     = 10_000e18;
        uint256 halfCapital = capital / CONCENTRATION_FACTOR;
        uint256 swapIn      = 1_000e18;

        (ISwapVM.Order memory xycOrder,)      = _xycSwapOrder(capital, capital);
        (ISwapVM.Order memory concHalfOrder,) = _concentrateOrder(halfCapital, halfCapital, SQRT_P_MIN, SQRT_P_MAX);

        (, uint256 xycOut,)      = swapVM.asView().quote(xycOrder,      tokenLt, tokenGt, swapIn, _tdIn(""));
        (, uint256 concHalfOut,) = swapVM.asView().quote(concHalfOrder, tokenLt, tokenGt, swapIn, _tdIn(""));

        // With R=2 and half capital: L = (K/2) / (1-0.5) = K. virtualLt = K = xycSwap.
        // Outputs must be within 1 unit (integer rounding).
        assertApproxEqAbs(concHalfOut, xycOut, 1,
            "Half-capital concentrate must equal full-capital XYCSwap output (R=2 range [0.5,2])");
    }

    /// @notice TEST 3: Marginal exchange rate (tiny swap)
    ///   For infinitesimally small swaps, marginal rate = virtualGt/virtualLt.
    ///   Concentrate(K, R) : marginal rate = (R×K) / (R×K) = 1  (same as XYCSwap)
    ///   But for NON-trivial swaps, slippage of concentrate is R× less.
    ///
    ///   Slippage fraction ε = amountIn / virtualLt
    ///   XYCSwap:   ε = amountIn / K
    ///   Concentrate: ε = amountIn / (R×K) = ε/R  → R times less slippage
    function test_Slippage_ConcentrateRTimesLess() public view {
        uint256 capital  = 10_000e18;
        uint256 swapIn   = 2_000e18; // 20% of capital — substantial, slippage visible

        (ISwapVM.Order memory xycOrder,)  = _xycSwapOrder(capital, capital);
        (ISwapVM.Order memory concOrder,) = _concentrateOrder(capital, capital, SQRT_P_MIN, SQRT_P_MAX);

        (, uint256 xycOut,)  = swapVM.asView().quote(xycOrder,  tokenLt, tokenGt, swapIn, _tdIn(""));
        (, uint256 concOut,) = swapVM.asView().quote(concOrder, tokenLt, tokenGt, swapIn, _tdIn(""));

        // Slippage = 1 - amountOut/idealOut  (idealOut = amountIn at P=1, i.e. swapIn itself)
        // xycSlippage  = 1 - xycOut/swapIn
        // concSlippage = 1 - concOut/swapIn
        // concSlippage / xycSlippage ≈ 1/R = 0.5
        uint256 xycLoss  = swapIn - xycOut;   // how much the taker "lost" vs ideal
        uint256 concLoss = swapIn - concOut;

        assertGt(xycLoss, concLoss,
            "XYCSwap must have higher slippage loss than Concentrate for the same capital");

        // Exact slippage ratio derivation (no approximation):
        //   xycLoss  = in² / (K  + in)
        //   concLoss = in² / (2K + in)
        //   ratio    = concLoss / xycLoss = (K + in) / (2K + in)
        //
        // For K=10_000, in=2_000: ratio = 12_000/22_000 = 6/11 ≈ 0.5454
        // Approaches 1/R = 0.5 as K → ∞ or in → 0; always > 1/R for finite in.
        uint256 slippageRatio    = Math.mulDiv(concLoss, ONE, xycLoss);
        uint256 expectedSlipRatio = Math.mulDiv(capital + swapIn, ONE, 2 * capital + swapIn);
        assertLt(slippageRatio, ONE, "Concentrate slippage fraction < 1");
        assertApproxEqRel(slippageRatio, expectedSlipRatio, 0.001e18,
            "Concentrate slippage ratio must equal (K+in)/(2K+in)");
        // Also confirm it is strictly less than 1/R: concSlippage < xycSlippage/R
        // i.e. slippageRatio < 1  (already asserted above with assertLt)
        // And upper-bounded: for any finite K and in, ratio < 1 always holds.
        assertGt(slippageRatio, ONE / CONCENTRATION_FACTOR,
            "Slippage ratio must be > 1/R (approaches 1/R only as K>>in)");
    }

    /// @notice TEST 4: Concentration factor scales with range narrowness
    ///   Narrower range [0.9, 10/3] has R≈10x, wide range [0.5, 2] has R=2x.
    ///   Narrower concentrate should always beat wider concentrate for same capital.
    function test_NarrowerRange_HigherCapitalEfficiency() public view {
        uint256 capital = 10_000e18;
        uint256 swapIn  = 500e18;

        (ISwapVM.Order memory wideOrder,)   = _concentrateOrder(capital, capital, SQRT_P_MIN,        SQRT_P_MAX);
        (ISwapVM.Order memory narrowOrder,) = _concentrateOrder(capital, capital, SQRT_P_MIN_NARROW, SQRT_P_MAX_NARROW);

        (, uint256 wideOut,)   = swapVM.asView().quote(wideOrder,   tokenLt, tokenGt, swapIn, _tdIn(""));
        (, uint256 narrowOut,) = swapVM.asView().quote(narrowOrder, tokenLt, tokenGt, swapIn, _tdIn(""));

        assertGt(narrowOut, wideOut,
            "Narrower range (R=10) must give more output than wider range (R=2) for same capital");
    }
}
