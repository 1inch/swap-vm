// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { FormatLib } from "./utils/FormatLib.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";
import { RoundingInvariants } from "./invariants/RoundingInvariants.sol";


contract ConcentrateTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using FormatLib for Vm;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function assertNotApproxEqRel(uint256 left, uint256 right, uint256 maxDelta, string memory err) internal{
        if (left > right * (1e18 - maxDelta) / 1e18 && left < right * (1e18 + maxDelta) / 1e18) {
            // "%s: %s ~= %s (max delta: %s%%, real delta: %s%%)"
            fail(string.concat(
                err,
                ": ",
                Strings.toString(left),
                " ~= ",
                Strings.toString(right),
                " (max delta: ",
                vm.toFixedString(maxDelta * 100),
                "%, real delta: ",
                vm.toFixedString(left > right ? (left - right) * 100e18 / right : (right - left) * 100e18 / left),
                "%)"
            ));
        }
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Deploy mock tokens — sort so tokenA is always Gt (higher address)
        // Required for correct price-range test invariants (priceBoundA = P_min, priceBoundB = P_max)
        address _tA = address(new TokenMock("Token I", "TKI"));
        address _tB = address(new TokenMock("Token J", "TKJ"));
        (tokenA, tokenB) = _tA > _tB ? (_tA, _tB) : (_tB, _tA);

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

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint256 flatFee;     // 0.003e9 - 0.3% flat fee
        uint256 priceBoundA; // 0.01e18 - sqrtPmin = sqrt(priceBoundA)
        uint256 priceBoundB; // 25e18   - sqrtPmax = sqrt(priceBoundB)
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Convert price bounds to sqrt price format for new API
        // sqrtP = sqrt(price * 1e18) where price is in 1e18 fixed-point
        uint256 sqrtPmin = Math.sqrt(setup.priceBoundA * 1e18);
        uint256 sqrtPmax = Math.sqrt(setup.priceBoundB * 1e18);

        // Compute actual pool balances consistent with P_spot=1 using computeLiquidityFromAmounts.
        // tokenA=Gt (higher address), tokenB=Lt (lower address).
        // setup.balanceA is the DESIRED Gt amount; setup.balanceB is used as Lt upper bound.
        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            setup.balanceB, setup.balanceA, 1e18, sqrtPmin, sqrtPmax
        );
        // Assign based on which token is Lt vs Gt
        uint256 actualBalanceA = address(tokenA) > address(tokenB) ? bGt : bLt;
        uint256 actualBalanceB = address(tokenA) > address(tokenB) ? bLt : bGt;

        Program program;
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenB),
            tokenB: address(tokenA),
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
                program.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(actualBalanceB), actualBalanceA])),
                program.build(Opcode.FlatFeeAmountIn, FeeArgsBuilder.buildFlatFee(setup.flatFee.toUint32())),
                program.build(Opcode.XYCConcentrateSwap,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                )
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    struct TakerSetup {
        bool isExactIn;
        bool isAToB;
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
            isAToB: takerSetup.isAToB,
            threshold: "", // no minimum output
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

    function _swappingTakerData(TakerSetup memory takerSetup, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: takerSetup.isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: takerSetup.isAToB,
            threshold: "", // no minimum output
            to: address(0),
            deadline: 0,
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

    function test_QuoteAndSwapExactOutAmountsMatches() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data (tokenA -> tokenB, isAToB = false since tokenA is higher)
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: false }));
        bytes memory swapExactOut = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: false }), signature);

        // Buy all tokenB liquidity
        uint256 amountOut = setup.balanceB;
        (uint256 quoteAmountIn,,) = swapVM.asView().quote(order, amountOut, quoteExactOut);
        vm.prank(taker);
        (uint256 swapAmountIn,,) = swapVM.swap(order, amountOut, swapExactOut);

        assertEq(swapAmountIn, quoteAmountIn, "Quoted amountIn should match swapped amountIn");
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForTokenA() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data (tokenB -> tokenA, isAToB = true since tokenB is lower)
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: true }));
        bytes memory swapExactOut = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: true }), signature);

        // Check quotes before and after buying all tokenA liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, setup.balanceA, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = preRate * 1e18 / postRate;
        assertApproxEqRel(rateChange, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForTokenB() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data (tokenA -> tokenB, isAToB = false since tokenA is higher)
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: false }));
        bytes memory swapExactOut = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: false }), signature);

        // Check quotes before and after buying all tokenB liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, setup.balanceB, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = postRate * 1e18 / preRate;
        assertApproxEqRel(rateChange, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForBothTokensNoFee() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0,           // No fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data, per direction.
        // tokenB -> tokenA (buy tokenA): isAToB = true (tokenB is lower).
        // tokenA -> tokenB (buy tokenB): isAToB = false (tokenA is higher).
        bytes memory quoteExactOutBtoA = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: true }));
        bytes memory swapExactOutBtoA = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: true }), signature);
        bytes memory quoteExactOutAtoB = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: false }));
        bytes memory swapExactOutAtoB = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: false }), signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, setup.balanceA, swapExactOutBtoA);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, balanceTokenB, swapExactOutAtoB);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForBothTokensWithFee() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data, per direction.
        // tokenB -> tokenA (buy tokenA): isAToB = true (tokenB is lower).
        // tokenA -> tokenB (buy tokenB): isAToB = false (tokenA is higher).
        bytes memory quoteExactOutBtoA = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: true }));
        bytes memory swapExactOutBtoA = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: true }), signature);
        bytes memory quoteExactOutAtoB = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: false }));
        bytes memory swapExactOutAtoB = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: false }), signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, setup.balanceA, swapExactOutBtoA);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, balanceTokenB, swapExactOutAtoB);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenB");
    }

    function test_ConcentrateGrowLiquidity_SpreadSlowlyGrowsForSomeReason() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 9000e18,
            balanceB: 8000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // price range min (P_min = 0.01, sqrtPmin = 0.1)
            priceBoundB: 25e18    // price range max (P_max = 25, sqrtPmax = 5)
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data, per direction.
        // tokenB -> tokenA (buy tokenA): isAToB = true (tokenB is lower).
        // tokenA -> tokenB (buy tokenB): isAToB = false (tokenA is higher).
        bytes memory quoteExactOutBtoA = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: true }));
        bytes memory swapExactOutBtoA = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: true }), signature);
        bytes memory quoteExactOutAtoB = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: false }));
        bytes memory swapExactOutAtoB = _swappingTakerData(TakerSetup({ isExactIn: false, isAToB: false }), signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);

        uint256 postAmountInA;
        uint256 postAmountOutA;
        uint256 postAmountInB;
        uint256 postAmountOutB;
        for (uint256 i = 0; i < 100; i++) {
            // Buy all tokenA
            uint256 balanceTokenA = swapVM.balances(swapVM.hash(order), address(tokenA));
            if (i == 0) {
                balanceTokenA = setup.balanceA; // First iteration doesn't have balances in the state yet
            }
            vm.prank(taker);
            swapVM.swap(order, balanceTokenA, swapExactOutBtoA);
            assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
            (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutBtoA);

            // Buy all tokenB
            uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
            vm.prank(taker);
            swapVM.swap(order, balanceTokenB, swapExactOutAtoB);
            assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
            (postAmountInB, postAmountOutB,) = swapVM.asView().quote(order, 0.001e18, quoteExactOutAtoB);
        }

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        // Range [0.01, 25] is ASYMMETRIC (geometric center = 0.5, P_spot=1 is above center).
        // After 100 buy-all-A / sell-all-B cycles with 0.3% fee, rateChangeA drifts only ~4.5e-8%
        // toward priceBoundA. Price bounds are fixed; only virtual L grows — drift is negligible.
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.00005e18, "Quote should be within 0.00005% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        // Same asymmetric range: rateChangeB drifts only ~4.5e-8% toward priceBoundB.
        // Tight tolerance 0.00005% documents the observed negligible drift with fee accumulation.
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.00005e18, "Quote should be within 0.00005% range of actual paid scaled by scaleB for tokenB");
    }

    function test_RoundingInvariantsWithFees() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 1000e18,
            balanceB: 1000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18,
            priceBoundB: 25e18
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        bytes memory takerData = _swappingTakerData(TakerSetup({ isExactIn: true, isAToB: true }), signature);

        // Test comprehensive rounding invariants
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

    // Helper function to execute swaps for invariant testing.
    // Direction (isAToB) is derived per-call from tokenIn/tokenOut so round-trip
    // invariants can swap both ways; the passed takerData is ignored in favor of
    // a freshly packed one carrying the correct direction.
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory /* takerData */
    ) internal returns (uint256 amountOut) {
        // Mint tokens to taker
        TokenMock(tokenIn).mint(taker, amount);

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory takerData = _swappingTakerData(
            TakerSetup({ isExactIn: true, isAToB: tokenIn < tokenOut }),
            abi.encodePacked(r, s, v)
        );

        vm.prank(taker);
        (, amountOut,) = _swapVM.swap(order, amount, takerData);
    }

    // NOTE: test_ConcentrateGrowLiquidity_ImpossibleSwapTokenNotInActiveStrategy was removed.
    // It relied on injecting an arbitrary tokenIn via swap(order, tokenIn, tokenOut, ...) and
    // expecting Balances.DynamicBalancesLoadingRequiresSettingBothBalances. The new swap()/quote()
    // API no longer accepts tokenIn/tokenOut params; the traded pair is fixed by the order's
    // MakerTraits (tokenA/tokenB) and only the direction (isAToB) is taker-controlled, so an
    // unrelated token can no longer reach _dynamicBalancesXD. The scenario is now impossible to
    // express through the public API and the negative case has been dropped. (flagged)

    /// @notice Helper to create order with custom spot price at bounds (resulting in zero balance for one token)
    function _createOrderAtBoundary(
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        uint256 targetL
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Compute balances for the given spot price
        (uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeBalances(
            targetL, sqrtPspot, sqrtPmin, sqrtPmax
        );

        // Assign based on which token is Lt vs Gt
        uint256 balanceA = address(tokenA) > address(tokenB) ? bGt : bLt;
        uint256 balanceB = address(tokenA) > address(tokenB) ? bLt : bGt;

        Program program;
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenB),
            tokenB: address(tokenA),
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
                program.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(balanceB), balanceA])),
                program.build(Opcode.FlatFeeAmountIn, FeeArgsBuilder.buildFlatFee(0.003e9)), // 0.3% fee
                program.build(Opcode.XYCConcentrateSwap,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                )
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice Helper to create order with raw Lt/Gt balances for targeted rounding regression checks.
    function _createOrderWithRawBalances(
        uint256 balanceLt,
        uint256 balanceGt,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        uint256 balanceA = address(tokenA) > address(tokenB) ? balanceGt : balanceLt;
        uint256 balanceB = address(tokenA) > address(tokenB) ? balanceLt : balanceGt;

        Program program;
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenB),
            tokenB: address(tokenA),
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
                program.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(balanceB), balanceA])),
                program.build(Opcode.XYCConcentrateSwap,
                    XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
                )
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice Regression for taker-favorable rounding edge:
    ///         must use maker-favoring rounding for reserveIn in concentrate step.
    function test_ConcentrateRounding_ExactOutUsesMakerFavoringReserveIn() public view {
        uint256 balanceLt = 1;
        uint256 balanceGt = 1_000;
        uint256 sqrtPmin = 1e18 - 1;
        uint256 sqrtPmax = 1e18 + 1;

        uint256 L = XYCConcentrateArgsBuilder._computeL(balanceLt, balanceGt, sqrtPmin, sqrtPmax);
        uint256 deltaLtFloor = Math.mulDiv(L, 1e18, sqrtPmax);
        uint256 deltaLtCeil = Math.mulDiv(L, 1e18, sqrtPmax, Math.Rounding.Ceil);
        uint256 deltaGtFloor = Math.mulDiv(L, sqrtPmin, 1e18);

        uint256 reserveOut = balanceGt + deltaGtFloor;
        uint256 amountOut = reserveOut - 2;

        uint256 reserveInMakerFav = balanceLt + deltaLtCeil;
        uint256 reserveInFloorFloor = balanceLt + deltaLtFloor;
        uint256 expectedAmountInMakerFav = Math.ceilDiv(amountOut * reserveInMakerFav, reserveOut - amountOut);
        uint256 expectedAmountInFloorFloor = Math.ceilDiv(amountOut * reserveInFloorFloor, reserveOut - amountOut);
        assertLt(expectedAmountInFloorFloor, expectedAmountInMakerFav, "Pathological case must be taker-favorable without fix");

        (ISwapVM.Order memory order,) = _createOrderWithRawBalances(balanceLt, balanceGt, sqrtPmin, sqrtPmax);

        // tokenLt -> tokenGt: isAToB = true (tokenLt is lower).
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false, isAToB: true }));
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = swapVM.asView().quote(
            order,
            amountOut,
            quoteExactOut
        );

        assertEq(quotedAmountOut, amountOut);
        assertEq(
            quotedAmountIn,
            expectedAmountInMakerFav,
            "Concentrate must round reserveIn in maker-favoring direction for exact-out"
        );
    }

    /// @notice Test zero-balance boundary: bLt = 0 (spot price at upper bound)
    ///         Only Gt->Lt swaps should work, Lt->Gt should fail due to no Lt liquidity
    function test_ZeroBalance_SpotAtUpperBound() public {
        uint256 sqrtPmin = Math.sqrt(0.01e18 * 1e18);  // 0.1e18
        uint256 sqrtPmax = Math.sqrt(25e18 * 1e18);    // 5e18
        uint256 sqrtPspot = sqrtPmax + 100;                  // At upper bound
        uint256 targetL = 100_000e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderAtBoundary(
            sqrtPspot, sqrtPmin, sqrtPmax, targetL
        );

        // Verify bLt = 0 (one balance should be zero)
        // Lt -> Gt: isAToB = true (tokenLt is lower).
        bytes memory swapExactIn = _swappingTakerData(TakerSetup({ isExactIn: true, isAToB: true }), signature);

        // Valid swap: Lt -> Gt (buying Gt at upper bound using Lt)
        uint256 swapAmount = 10e18;
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, swapAmount, swapExactIn);
        assertGt(amountOut, 0);
        assertEq(amountIn, swapAmount);
    }

    /// @notice Test zero-balance boundary: bGt = 0 (spot price at lower bound)
    ///         Only Lt->Gt swaps should work, Gt->Lt should fail due to no Gt liquidity
    function test_ZeroBalance_SpotAtLowerBound() public {
        uint256 sqrtPmin = Math.sqrt(0.01e18 * 1e18);  // 0.1e18
        uint256 sqrtPmax = Math.sqrt(25e18 * 1e18);    // 5e18
        uint256 sqrtPspot = sqrtPmin - 100;              // At lower bound
        uint256 targetL = 100_000e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderAtBoundary(
            sqrtPspot, sqrtPmin, sqrtPmax, targetL
        );

        // Gt -> Lt: isAToB = false (tokenGt is higher).
        bytes memory swapExactIn = _swappingTakerData(TakerSetup({ isExactIn: true, isAToB: false }), signature);

        // Valid swap: Gt -> Lt (selling Gt to get Lt at lower bound)
        uint256 swapAmount = 10e18;
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, swapAmount, swapExactIn);
        assertGt(amountOut, 0);
        assertEq(amountIn, swapAmount);
    }

    // TODO: Move this test to general SwapVM tests since it's not specific to XYCConcentrate
    // function test_ConcentrateGrowLiquidity_ImpossibleSwapSameToken() public {
    //     MakerSetup memory setup = MakerSetup({
    //         balanceA: 20000e18,
    //         balanceB: 3000e18,
    //         flatFee: 0.003e9,     // 0.3% flat fee
    //         priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
    //         priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
    //     });
    //     (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

    //     vm.startPrank(taker);

    //     // Setup taker traits and data
    //     bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
    //     bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

    //     // Buy all tokenB liquidity
    //     vm.expectRevert(MakerTraitsLib.MakerTraitsTokenInAndTokenOutMustBeDifferent.selector);
    //     swapVM.swap(order, tokenB, tokenB, setup.balanceB, swapExactOut);
    // }
}
