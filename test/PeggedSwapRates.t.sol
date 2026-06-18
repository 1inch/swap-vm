// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/// @title PeggedSwap rate / decimal normalization tests
/// @notice The rest of the PeggedSwap suite uses equal decimals (rateLt = rateGt = 1), where the
///         rate multipliers are identity and never affect the result. These tests use DIFFERENT,
///         non-unit rates (simulating tokens with different decimals) in both directions and both
///         exact modes, exercising the rate normalization math (`x0_raw * rateIn`, `y0_raw * rateOut`,
///         `(y0 - y1) / rateOut`, etc.). For each scenario they assert:
///           - the absolute decimal-adjusted output (peg conversion within slippage),
///           - quote() == swap() parity,
///           - the maker invariant does not decrease (rounding favors the maker),
///         swept across the linear-width range (0, tight-stable, cap) and down to dust amounts.
contract PeggedSwapRatesTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenLt; // lower address -> rateLt
    address public tokenGt; // higher address -> rateGt

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    // Distinct, non-unit rates so every rate multiplication/division is meaningfully exercised.
    uint256 constant RATE_LT = 1e12; // e.g. token with 6 decimals scaled to 18
    uint256 constant RATE_GT = 1e6;  // e.g. token with 12 decimals scaled to 18

    // Normalized reserves are equal (peg 1:1 in normalized space) => raw balances differ by RATE.
    uint256 constant NORM = 1e30;
    uint256 constant BAL_LT_RAW = NORM / RATE_LT; // 1e18
    uint256 constant BAL_GT_RAW = NORM / RATE_GT; // 1e24

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (tokenLt, tokenGt) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? maker : taker;
            TokenMock(tokenLt).mint(who, 1e33);
            TokenMock(tokenGt).mint(who, 1e33);
            vm.prank(who);
            TokenMock(tokenLt).approve(address(swapVM), type(uint256).max);
            vm.prank(who);
            TokenMock(tokenGt).approve(address(swapVM), type(uint256).max);
        }
    }

    function _order(uint256 linearWidth) internal view returns (ISwapVM.Order memory) {
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenLt, tokenGt]),
                dynamic([BAL_LT_RAW, BAL_GT_RAW])
            )),
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: NORM,        // Lt normalized reserve = BAL_LT_RAW * RATE_LT
                    y0: NORM,        // Gt normalized reserve = BAL_GT_RAW * RATE_GT
                    linearWidth: linearWidth,
                    rateLt: RATE_LT,
                    rateGt: RATE_GT
                })))
        );
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker, receiver: address(0), shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false, allowZeroAmountIn: false,
            hasPreTransferInHook: false, hasPostTransferInHook: false,
            hasPreTransferOutHook: false, hasPostTransferOutHook: false,
            preTransferInTarget: address(0), preTransferInData: "",
            postTransferInTarget: address(0), postTransferInData: "",
            preTransferOutTarget: address(0), preTransferOutData: "",
            postTransferOutTarget: address(0), postTransferOutData: "",
            program: programBytes
        }));
    }

    function _takerData(bool isExactIn, ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker, isExactIn: isExactIn, shouldUnwrapWeth: false,
            hasPreTransferInCallback: false, hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false, isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false, threshold: "", to: address(0), deadline: 0,
            preTransferInHookData: "", postTransferInHookData: "",
            preTransferOutHookData: "", postTransferOutHookData: "",
            preTransferInCallbackData: "", preTransferOutCallbackData: "",
            instructionsArgs: "", signature: ""
        })), abi.encodePacked(r, s, v));
    }

    // Linear-width values to sweep: pure sqrt, mid-range, and the cap (A <= 2 => linearWidth <= 2e27).
    uint256[3] internal AS = [uint256(0), 1e27, 2e27];

    // Slack for the invariant recomputation (absorbs sqrt/division flooring in the re-derivation).
    uint256 constant INV_SLACK = 5e24;

    /// @dev Quote, then swap the same order, and assert quote == swap and exact-side bookkeeping.
    function _quoteAndSwap(address tokenIn, address tokenOut, uint256 amount, bool isExactIn, uint256 linearWidth)
        internal
        returns (uint256 sIn, uint256 sOut)
    {
        ISwapVM.Order memory order = _order(linearWidth);
        bytes memory takerData = _takerData(isExactIn, order);

        (uint256 qIn, uint256 qOut,) = swapVM.asView().quote(order, tokenIn, tokenOut, amount, takerData);

        vm.prank(taker);
        (sIn, sOut,) = swapVM.swap(order, tokenIn, tokenOut, amount, takerData);

        // (2) quote/swap parity at non-unit rates
        assertEq(sIn, qIn, "quote/swap amountIn mismatch");
        assertEq(sOut, qOut, "quote/swap amountOut mismatch");

        if (isExactIn) {
            assertEq(sIn, amount, "ExactIn must consume the requested amountIn");
        } else {
            assertEq(sOut, amount, "ExactOut must deliver the requested amountOut");
        }
    }

    /// @dev (3)/(1) Maker safety: the normalized invariant must not decrease after the swap.
    ///      Both reserves start normalized to NORM, so the initial invariant is the equilibrium one.
    function _assertMakerInvariantNonDecreasing(
        address tokenIn,
        address tokenOut,
        uint256 sIn,
        uint256 sOut,
        uint256 linearWidth
    ) internal view {
        uint256 rateIn = tokenIn == tokenLt ? RATE_LT : RATE_GT;
        uint256 rateOut = tokenOut == tokenLt ? RATE_LT : RATE_GT;
        uint256 balInRaw = tokenIn == tokenLt ? BAL_LT_RAW : BAL_GT_RAW;
        uint256 balOutRaw = tokenOut == tokenLt ? BAL_LT_RAW : BAL_GT_RAW;

        uint256 invBefore = PeggedSwapMath.invariantFromReserves(
            balInRaw * rateIn, balOutRaw * rateOut, NORM, NORM, linearWidth
        );
        uint256 invAfter = PeggedSwapMath.invariantFromReserves(
            (balInRaw + sIn) * rateIn, (balOutRaw - sOut) * rateOut, NORM, NORM, linearWidth
        );

        assertGe(invAfter + INV_SLACK, invBefore, "maker invariant must not decrease (rounding favors maker)");
    }

    /// @dev Run one isolated scenario from the fresh pool (snapshot/revert resets the per-order
    ///      balances persisted by Balances._dynamicBalancesXD).
    /// @param dust when true, skip the peg-approximation check (dust output may round to 0 / far from peg)
    function _scenario(bool isExactIn, bool ltToGt, uint256 linearWidth, uint256 amount, bool dust) internal {
        uint256 snap = vm.snapshot();

        (address tokenIn, address tokenOut) = ltToGt ? (tokenLt, tokenGt) : (tokenGt, tokenLt);
        uint256 rateIn = tokenIn == tokenLt ? RATE_LT : RATE_GT;
        uint256 rateOut = tokenOut == tokenLt ? RATE_LT : RATE_GT;

        (uint256 sIn, uint256 sOut) = _quoteAndSwap(tokenIn, tokenOut, amount, isExactIn, linearWidth);

        if (isExactIn) {
            // amountOut(raw) ≈ amountIn(raw) * rateIn / rateOut at the 1:1 normalized peg.
            uint256 expectedOut = Math.mulDiv(amount, rateIn, rateOut);
            assertLe(sOut, expectedOut, "output must not exceed peg conversion (maker protection)");
            if (!dust) {
                assertGt(sOut, 0, "output must be positive");
                assertApproxEqRel(sOut, expectedOut, 0.02e18, "output must match decimal-adjusted peg within slippage");
            }
        } else {
            uint256 expectedIn = Math.mulDiv(amount, rateOut, rateIn);
            assertGe(sIn, expectedIn, "input must not be below peg conversion (maker protection)");
            if (!dust) {
                assertGt(sIn, 0, "input must be positive");
                assertApproxEqRel(sIn, expectedIn, 0.02e18, "input must match decimal-adjusted peg within slippage");
            }
        }

        _assertMakerInvariantNonDecreasing(tokenIn, tokenOut, sIn, sOut, linearWidth);

        vm.revertTo(snap);
    }

    // ── (4) Peg accuracy + (2) quote parity + (3) invariant, swept across A ──────

    function test_PeggedSwap_Rates_ExactIn_LtToGt() public {
        for (uint256 i; i < AS.length; i++) _scenario(true, true, AS[i], BAL_LT_RAW / 100, false);
    }

    function test_PeggedSwap_Rates_ExactIn_GtToLt() public {
        for (uint256 i; i < AS.length; i++) _scenario(true, false, AS[i], BAL_GT_RAW / 100, false);
    }

    function test_PeggedSwap_Rates_ExactOut_LtToGt() public {
        for (uint256 i; i < AS.length; i++) _scenario(false, true, AS[i], BAL_GT_RAW / 100, false);
    }

    function test_PeggedSwap_Rates_ExactOut_GtToLt() public {
        for (uint256 i; i < AS.length; i++) _scenario(false, false, AS[i], BAL_LT_RAW / 100, false);
    }

    // ── (1) Dust swaps: rate-division remainder dominates; rounding must favor the maker ──

    /// @dev Dust scenario. When the rate-flooring drives the output to 0 the protocol rejects the
    ///      swap (no free dust extraction). Otherwise the realized amount must round in the maker's
    ///      favor and the maker invariant must not decrease.
    function _dustScenario(bool isExactIn, bool ltToGt, uint256 linearWidth, uint256 amount) internal {
        uint256 snap = vm.snapshot();

        (address tokenIn, address tokenOut) = ltToGt ? (tokenLt, tokenGt) : (tokenGt, tokenLt);
        uint256 rateIn = tokenIn == tokenLt ? RATE_LT : RATE_GT;
        uint256 rateOut = tokenOut == tokenLt ? RATE_LT : RATE_GT;

        ISwapVM.Order memory order = _order(linearWidth);
        bytes memory takerData = _takerData(isExactIn, order);

        // quote() applies taker traits, so it reverts when the rate-flooring drives the realized
        // amount to zero — exactly the "no free dust extraction" maker protection. In that case the
        // swap must revert too; otherwise the realized amount must round in the maker's favor.
        try swapVM.asView().quote(order, tokenIn, tokenOut, amount, takerData) returns (uint256 qIn, uint256 qOut, bytes32) {
            vm.prank(taker);
            (uint256 sIn, uint256 sOut,) = swapVM.swap(order, tokenIn, tokenOut, amount, takerData);
            assertEq(sIn, qIn, "dust quote/swap amountIn mismatch");
            assertEq(sOut, qOut, "dust quote/swap amountOut mismatch");
            if (isExactIn) {
                assertLe(sOut, Math.mulDiv(amount, rateIn, rateOut), "dust output must not exceed peg conversion");
            } else {
                assertGe(sIn, Math.mulDiv(amount, rateOut, rateIn), "dust input must not be below peg conversion");
            }
            _assertMakerInvariantNonDecreasing(tokenIn, tokenOut, sIn, sOut, linearWidth);
        } catch {
            vm.prank(taker);
            vm.expectRevert();
            swapVM.swap(order, tokenIn, tokenOut, amount, takerData);
        }

        vm.revertTo(snap);
    }

    /// @notice Tiny swaps where the rate-division remainder is the dominant term, across both
    ///         directions and both A extremes. The fine-grained-output direction (Gt->Lt, where
    ///         rateOut = 1e12) is the key stressor.
    function test_PeggedSwap_Rates_Dust_RoundingFavorsMaker() public {
        uint256[2] memory dustAs = [uint256(0), 2e27];
        for (uint256 i; i < dustAs.length; i++) {
            uint256 A = dustAs[i];
            _dustScenario(true, false, A, 1e6); // ExactIn Gt->Lt (output token rateOut = 1e12)
            _dustScenario(true, true, A, 1);    // ExactIn Lt->Gt, 1 wei
            _dustScenario(false, false, A, 1);  // ExactOut Gt->Lt, 1 wei out
            _dustScenario(false, true, A, 1);   // ExactOut Lt->Gt, 1 wei out
        }
    }
}
