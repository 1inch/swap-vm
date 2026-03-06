// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title ConcentrateXYCRounding
 * @notice Tests that rounding errors in ConcentrateXYC do NOT give takers an advantage
 * @dev Tests 3 scenarios (standard, narrow, asymmetric ranges) with:
 *      1. Accumulation attacks (N small swaps vs 1 big swap)
 *      2. Round-trip attacks (A→B→A cycles)
 *      3. Maker protection (liquidity must grow, not shrink)
 */
contract ConcentrateXYCRounding is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    uint256 constant ONE = 1e18;
    uint32 constant FEE_BPS = 3_000_000; // 0.3%

    SwapVMRouter public swapVM;
    address public tokenLt; // lower address
    address public tokenGt; // higher address
    address public maker;
    uint256 public makerPK;
    address public taker = makeAddr("taker");

    constructor() OpcodesDebug(address(new Aqua())) {}

    function setUp() public {
        makerPK = 0x1234;
        maker = vm.addr(makerPK);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Ensure tokenLt < tokenGt
        TokenMock tA = new TokenMock("TokenA", "A");
        TokenMock tB = new TokenMock("TokenB", "B");
        (tokenLt, tokenGt) = address(tA) < address(tB)
            ? (address(tA), address(tB))
            : (address(tB), address(tA));

        // Fund both maker and taker
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

    /// @notice Helper: run N swap rounds (Lt→Gt and Gt→Lt alternating)
    function _runRoundTrips(
        ISwapVM.Order memory order,
        bytes memory td,
        uint256 swapSizeLt,
        uint256 swapSizeGt,
        uint256 rounds
    ) internal {
        vm.startPrank(taker);
        for (uint256 i = 0; i < rounds; i++) {
            swapVM.swap(order, tokenLt, tokenGt, swapSizeLt, td);
            swapVM.swap(order, tokenGt, tokenLt, swapSizeGt, td);
        }
        vm.stopPrank();
    }

    /// @notice Core test: verify no accumulation exploit + taker loses + maker protected
    function _testRoundingProtection(
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        string memory label
    ) internal {
        uint256 avail = 100_000e18;
        (uint256 initialL, uint256 bLt, uint256 bGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(avail, avail, sqrtPspot, sqrtPmin, sqrtPmax);

        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(bLt, bGt, sqrtPmin, sqrtPmax);
        bytes32 h = swapVM.hash(order);
        bytes memory td = _td(sig, true);

        // Value-balanced swap sizes at spot price
        uint256 pSpot = sqrtPspot * sqrtPspot / ONE;
        uint256 bLtInGt = Math.mulDiv(bLt, pSpot, ONE);
        uint256 smallSide = bLtInGt < bGt ? bLtInGt : bGt;
        uint256 swapSizeGt = smallSide / 100; // 1% of smaller side
        uint256 swapSizeLt = Math.mulDiv(swapSizeGt, ONE, pSpot);
        if (swapSizeLt < 1e14) {
            swapSizeLt = 1e14;
            swapSizeGt = Math.mulDiv(1e14, pSpot, ONE);
        }

        // === Check 1: Accumulation (many small != one big) ===
        uint256 atomicLt = swapSizeLt / 100; // tiny amount

        uint256 snap = vm.snapshot();
        // N small swaps
        uint256 sumSmall = 0;
        vm.startPrank(taker);
        for (uint256 i = 0; i < 100; i++) {
            (, uint256 out,) = swapVM.swap(order, tokenLt, tokenGt, atomicLt, td);
            sumSmall += out;
        }
        vm.stopPrank();
        vm.revertTo(snap);

        // 1 big swap (reset state first)

        vm.prank(taker);
        (, uint256 oneBig,) = swapVM.swap(order, tokenLt, tokenGt, atomicLt * 100, td);

        // Taker should NOT benefit from splitting
        assertLe(sumSmall, oneBig + 100, string.concat(label, ": accumulation exploit detected"));

        // === Check 2: Round-trips (taker loses money) ===
        uint256 takerLtBefore = TokenMock(tokenLt).balanceOf(taker);
        uint256 takerGtBefore = TokenMock(tokenGt).balanceOf(taker);

        _runRoundTrips(order, td, swapSizeLt, swapSizeGt, 50);

        uint256 takerLtAfter = TokenMock(tokenLt).balanceOf(taker);
        uint256 takerGtAfter = TokenMock(tokenGt).balanceOf(taker);

        // Convert to common denomination (Gt units) to check total value
        uint256 valueBefore = takerGtBefore + Math.mulDiv(takerLtBefore, pSpot, ONE);
        uint256 valueAfter = takerGtAfter + Math.mulDiv(takerLtAfter, pSpot, ONE);

        // Taker MUST lose money (fees > rounding)
        assertLt(valueAfter, valueBefore, string.concat(label, ": taker profited from round-trips"));

        // === Check 3: Maker protection (liquidity grows) ===
        (uint256 finalL,) = XYCConcentrateArgsBuilder.computeLiquidityAndPrice(
            swapVM.balances(h, tokenLt),
            swapVM.balances(h, tokenGt),
            sqrtPmin,
            sqrtPmax
        );

        assertGe(finalL, initialL, string.concat(label, ": maker liquidity decreased"));
    }

    /// @notice Test 1: Standard range (0.8 - 1.25)
    function test_RoundingProtection_StandardRange() public {
        _testRoundingProtection(
            ONE,                      // sqrtPspot = 1.0
            Math.sqrt(0.8e36),       // sqrtPmin
            Math.sqrt(1.25e36),      // sqrtPmax
            "StandardRange"
        );
    }

    /// @notice Test 2: Narrow range (0.95 - 1.05) - maximum concentration
    function test_RoundingProtection_NarrowRange() public {
        _testRoundingProtection(
            ONE,                      // sqrtPspot = 1.0
            Math.sqrt(0.95e36),      // sqrtPmin
            Math.sqrt(1.05e36),      // sqrtPmax
            "NarrowRange"
        );
    }

    /// @notice Test 3: Asymmetric range (0.5 - 1.05) - heavily skewed
    function test_RoundingProtection_AsymmetricRange() public {
        _testRoundingProtection(
            ONE,                      // sqrtPspot = 1.0
            Math.sqrt(0.5e36),       // sqrtPmin
            Math.sqrt(1.05e36),      // sqrtPmax
            "AsymmetricRange"
        );
    }
}
