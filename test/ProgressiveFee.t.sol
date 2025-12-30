// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";
import { ExactInOutSymmetry } from "./invariants/ExactInOutSymmetry.t.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { FeeExperimental, FeeArgsBuilderExperimental } from "../src/instructions/FeeExperimental.sol";
import { Debug } from "../src/instructions/Debug.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

uint256 constant ONE = 1e18;

contract ProgressiveFeeTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouterDebug public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouterDebug(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 1_000_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000_000e18);

        // Approve SwapVM to spend tokens
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
        uint32 progressiveFeeBps;
        uint32 flatFeeBps;
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            // 1. Set initial token balances
            program.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
            // 2. Apply progressive fee based on rate change
            program.build(FeeExperimental._progressiveFeeInXD,
                FeeArgsBuilderExperimental.buildProgressiveFee(setup.progressiveFeeBps)),
            // 3. Apply flat fee on top of progressive fee
            (setup.flatFeeBps) > 0 ? program.build(Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(setup.flatFeeBps)) : bytes(""),
            // 4. Perform the swap
            program.build(XYCSwap._xycSwapXD)
        );

        // === Create Order ===
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
            program: programBytes
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    struct TakerSetup {
        bool isExactIn;
    }

    function _makeTakerData(TakerSetup memory setup, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: setup.isExactIn,
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

    function _calculateIncreaseInvPerUnit(uint256 balanceA, uint256 balanceB, uint256 amountIn, uint256 amountOut, uint256 unitAmount) internal pure returns (uint256) {
        uint256 invIncreaseRate = (balanceA + amountIn) * (balanceB - amountOut) * ONE / (balanceA * balanceB);
        return (invIncreaseRate - ONE) * ONE / unitAmount;
    }

    function test_ProgressiveFeeIn_ExactIn_IncreasesWithLargerSwaps() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Quoting order
        uint256 amountIn1 = 10e18;
        uint256 amountIn2 = 20e18;
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 amountOut1,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn1, exactInTakerData);
        (, uint256 amountOut2,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn2, exactInTakerData);

        // Analyze results
        uint256 increaseInvPerAmountIn1 = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn1, amountOut1, amountIn1);
        uint256 increaseInvPerAmountIn2 = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn2, amountOut2, amountIn2);

        assertLt(increaseInvPerAmountIn1, increaseInvPerAmountIn2, "Larger swap should have worse rate due to progressive fee");
    }

    function test_ProgressiveFeeIn_ExactOut_IncreasesWithLargerSwaps() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Quoting order
        uint256 amountOut1 = 10e18;
        uint256 amountOut2 = 20e18;
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 amountIn1,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut1, exactOutTakerData);
        (uint256 amountIn2,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut2, exactOutTakerData);

        // Analyze results
        uint256 increaseInvPerAmountOut1 = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn1, amountOut1, amountOut1);
        uint256 increaseInvPerAmountOut2 = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn2, amountOut2, amountOut2);

        assertLt(increaseInvPerAmountOut1, increaseInvPerAmountOut2, "Larger swap should have worse rate due to progressive fee");
    }

    function test_ProgressiveFeeIn_ExactIn_DecreasesBySplittingAmount() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Quoting order
        uint256 amountIn1 = 10e18;
        uint256 amountIn2 = 20e18;
        uint256 amountInTotal = amountIn1 + amountIn2;
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), signature);
        (, uint256 amountOutTotal,) = swapVM.asView().quote(order, tokenA, tokenB, amountInTotal, exactInTakerData);

        vm.prank(taker);
        (, uint256 amountOut1,) = swapVM.swap(order, tokenA, tokenB, amountIn1, exactInTakerData);
        (, uint256 amountOut2,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn2, exactInTakerData);

        // Analyze results
        assertGt(amountInTotal * ONE / amountOutTotal, amountInTotal * ONE / (amountOut1 + amountOut2), "Splitting amounts should result in better rate compared to single swap");
    }

    function test_ProgressiveFeeIn_ExactOut_DecreasesBySplittingAmount() public {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Quoting order
        uint256 amountOut1 = 10e18;
        uint256 amountOut2 = 10e18;
        uint256 amountOutTotal = amountOut1 + amountOut2;
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), signature);
        (uint256 amountInTotal,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOutTotal, exactOutTakerData);

        vm.prank(taker);
        (uint256 amountIn1,,) = swapVM.swap(order, tokenA, tokenB, amountOut1, exactOutTakerData);
        (uint256 amountIn2,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut2, exactOutTakerData);

        // Analyze results
        assertGt(amountInTotal * ONE / amountOutTotal, (amountIn1 + amountIn2) * ONE / amountOutTotal, "Splitting amounts should result in better rate compared to single swap");
    }

    function test_ProgressiveFeeIn_ExactIn_ProvidesMoreFairRateThanFlatFees() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory orderWithProgressiveFee,) = _createOrder(setup);
        setup.flatFeeBps = 0.10e9; // 10% flat fee
        setup.progressiveFeeBps = 0;
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);

        // Quoting order
        uint256 amountInWhereFeesEqual = 111e18;
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");

        for (uint256 amountIn = 10e18; amountIn <= 400e18; amountIn += 10e18) {
            (, uint256 amountOutProgressive,) = swapVM.asView().quote(orderWithProgressiveFee, tokenA, tokenB, amountIn, exactInTakerData);
            (, uint256 amountOutFlat,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountIn, exactInTakerData);

            if (amountIn < amountInWhereFeesEqual) {
                assertGt(amountOutProgressive, amountOutFlat, "Progressive fee should provide better rate for smaller amounts");
            } else {
                assertLe(amountOutProgressive, amountOutFlat, "Flat fee should provide better rate for larger amounts");
            }
        }
    }

    function test_ProgressiveFeeIn_ExactOut_ProvidesMoreFairRateThanFlatFees() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory orderWithProgressiveFee,) = _createOrder(setup);
        setup.flatFeeBps = 0.10e9; // 10% flat fee
        setup.progressiveFeeBps = 0;
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);

        // Quoting order
        uint256 amountOutWhereFeesEqual = 90e18;
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");

        for (uint256 amountOut = 10e18; amountOut < 190e18; amountOut += 10e18) {
            (uint256 amountInProgressive,,) = swapVM.asView().quote(orderWithProgressiveFee, tokenA, tokenB, amountOut, exactOutTakerData);
            (uint256 amountInFlat,,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountOut, exactOutTakerData);

            if (amountOut > amountOutWhereFeesEqual) {
                assertGe(amountInProgressive, amountInFlat, "Progressive fee should provide better rate for smaller amounts");
            } else {
                assertLt(amountInProgressive, amountInFlat, "Flat fee should provide better rate for larger amounts");
            }
        }
    }

    function test_ProgressiveFeeIn_InvariantGrowthScalesWithPriceImpact() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");

        uint256[] memory amounts = dynamic([uint256(10e18), 20e18, 30e18, 40e18, 100e18, 135e18]);
        uint256 ratioPrev = 0;
        uint256 tolerance = 1e10;

        for (uint i = 0; i < amounts.length; i++) {
            (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amounts[i], exactOutTakerData);
            uint256 priceImpact = (amountIn * setup.balanceB) * ONE / (amountOut * setup.balanceA) - ONE;
            uint256 invGrowth = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOut, amountOut);
            uint256 ratio = invGrowth * ONE / priceImpact;

            if (i > 0) {
                assertApproxEqAbs(ratioPrev, ratio, tolerance, "Non-linear relationship");
            }

            ratioPrev = ratio;
        }
    }

    function test_ProgressiveFeeIn_ExactIn_ZeroFeeBehavesLikeNoFeeStrategy() public view {
        // Creating order with zero fee
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0, // 0% fee should not affect swap
            flatFeeBps: 0 // 0% fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        uint256[] memory amounts = dynamic([uint256(1e18), 10e18, 50e18]);
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");

        for (uint i = 0; i < amounts.length; i++) {
            (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amounts[i], exactInTakerData);

            // Expected result from standard AMM formula: xy = k
            uint256 expectedOut = amounts[i] * setup.balanceB / (setup.balanceA + amounts[i]);

            assertEq(amountOut, expectedOut, "Should match no-fee AMM formula");
            assertEq(amountIn, amounts[i], "Input amount should not change");

            uint256 invGrowth = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOut, amountIn);
            assertEq(invGrowth, 0, "Invariant should not grow with zero fee");
        }
    }

    function test_ProgressiveFeeIn_ExactOut_ZeroFeeBehavesLikeNoFeeStrategy() public view {
        // Creating order with zero fee
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0, // 0% fee should not affect swap
            flatFeeBps: 0 // 0% fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        uint256[] memory amounts = dynamic([uint256(1e18), 10e18, 50e18]);
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");

        for (uint i = 0; i < amounts.length; i++) {
            (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amounts[i], exactOutTakerData);

            // Expected result from standard AMM formula: xy = k
            uint256 expectedIn = (amounts[i] * setup.balanceA + (setup.balanceB - amounts[i]) - 1) / (setup.balanceB - amounts[i]);

            assertEq(amountIn, expectedIn, "Should match no-fee AMM formula");
            assertEq(amountOut, amounts[i], "Output amount should not change");

            uint256 invGrowth = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOut, amountOut);
            assertEq(invGrowth, 0, "Invariant should not grow with zero fee");
        }
    }

    function test_ProgressiveFeeIn_ExactIn_WithFlatFees() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0.05e9 // 5% flat fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Quoting order with both fees
        uint256 amountIn = 20e18;
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 amountOutWithBothFees,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn, exactInTakerData);

        setup.flatFeeBps = 0; // Remove flat fee
        (ISwapVM.Order memory orderWithFlatFees,) = _createOrder(setup);
        (, uint256 amountOutWithProgressiveFee,) = swapVM.asView().quote(orderWithFlatFees, tokenA, tokenB, amountIn, exactInTakerData);

        setup.progressiveFeeBps = 0; // Remove progressive fee
        setup.flatFeeBps = 0.05e9; // Restore flat fee
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);
        (, uint256 amountOutWithFlatFee,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountIn, exactInTakerData);

        // Analyze results
        uint256 increaseInvPerAmountInBothFees = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOutWithBothFees, amountIn);
        uint256 increaseInvPerAmountInProgressiveFee = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOutWithProgressiveFee, amountIn);
        uint256 increaseInvPerAmountInFlatFee = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountIn, amountOutWithFlatFee, amountIn);

        assertGt(increaseInvPerAmountInBothFees, increaseInvPerAmountInProgressiveFee, "Combined fees should increase invariant more than progressive fee alone");
        assertGt(increaseInvPerAmountInBothFees, increaseInvPerAmountInFlatFee, "Combined fees should increase invariant more than flat fee alone");
        assertLt(increaseInvPerAmountInProgressiveFee, increaseInvPerAmountInFlatFee, "Progressive fee should increase invariant less than flat fee alone");
    }

    function test_ProgressiveFeeIn_ExactOut_WithFlatFees() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0.05e9 // 5% flat fee
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Quoting order with both fees
        uint256 amountOut = 20e18;
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 amountInWithBothFees,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, exactOutTakerData);

        setup.flatFeeBps = 0; // Remove flat fee
        (ISwapVM.Order memory orderWithProgressiveFee,) = _createOrder(setup);
        (uint256 amountInWithProgressiveFee,,) = swapVM.asView().quote(orderWithProgressiveFee, tokenA, tokenB, amountOut, exactOutTakerData);

        setup.progressiveFeeBps = 0; // Remove progressive fee
        setup.flatFeeBps = 0.05e9; // Restore flat fee
        (ISwapVM.Order memory orderWithFlatFee,) = _createOrder(setup);
        (uint256 amountInWithFlatFee,,) = swapVM.asView().quote(orderWithFlatFee, tokenA, tokenB, amountOut, exactOutTakerData);

        // Analyze results
        uint256 increaseInvPerAmountOutBothFees = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountInWithBothFees, amountOut, amountOut);
        uint256 increaseInvPerAmountOutProgressiveFee = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountInWithProgressiveFee, amountOut, amountOut);
        uint256 increaseInvPerAmountOutFlatFee = _calculateIncreaseInvPerUnit(setup.balanceA, setup.balanceB, amountInWithFlatFee, amountOut, amountOut);

        assertGt(increaseInvPerAmountOutBothFees, increaseInvPerAmountOutProgressiveFee, "Combined fees should increase invariant more than progressive fee alone");
        assertGt(increaseInvPerAmountOutBothFees, increaseInvPerAmountOutFlatFee, "Combined fees should increase invariant more than flat fee alone");
        assertLt(increaseInvPerAmountOutProgressiveFee, increaseInvPerAmountOutFlatFee, "Progressive fee should increase invariant less than flat fee alone");
    }

    function test_ProgressiveFeeIn_ConsistentForExactInAndExactOut() public view {
        // Creating order
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Quoting exact in
        uint256 amountIn = 20e18;
        bytes memory exactInTakerData = _makeTakerData(TakerSetup({ isExactIn: true }), "");
        (, uint256 amountOut,) = swapVM.asView().quote(order, tokenA, tokenB, amountIn, exactInTakerData);

        // Quoting exact out
        bytes memory exactOutTakerData = _makeTakerData(TakerSetup({ isExactIn: false }), "");
        (uint256 amountInQuotedBack,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, exactOutTakerData);

        // Analyze results
        assertApproxEqAbs(amountIn, amountInQuotedBack, 1e12, "Quoted back amountIn should match original within tolerance");
    }

    // === Tests using ExactInOutSymmetry library ===

    /**
     * @notice Progressive fees now maintain near-perfect symmetry with new formula
     * @dev The new implementation uses dx_eff = dx / (1 + λ * dx / x) which is mathematically reversible.
     * Only tiny asymmetry (~1 gwei) remains due to intentional ceiling operations for safety.
     */
    function test_ProgressiveFee_MaintainsSymmetry() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0.10e9, // 10% progressive fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // Progressive fees now maintain symmetry with tiny rounding tolerance
        ExactInOutSymmetry.assertSymmetryBatch(
            swapVM,
            order,
            tokenA,
            tokenB,
            dynamic([uint256(1e18), 10e18, 30e18, 50e18]),
            _makeTakerData(TakerSetup({ isExactIn: true }), ""),
            _makeTakerData(TakerSetup({ isExactIn: false }), ""),
            1e10 // small tolerance for ceiling operations
        );
    }

    /**
     * @notice Test that zero progressive fee maintains symmetry
     * @dev This validates that the asymmetry is indeed caused by the progressive fee
     */
    function test_SymmetryInvariant_ZeroProgressiveFee() public view {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            progressiveFeeBps: 0, // No progressive fee
            flatFeeBps: 0
        });
        (ISwapVM.Order memory order,) = _createOrder(setup);

        // With zero fees, symmetry should be perfect
        ExactInOutSymmetry.assertSymmetryBatch(
            swapVM,
            order,
            tokenA,
            tokenB,
            dynamic([uint256(1e18), 10e18, 30e18, 50e18]),
            _makeTakerData(TakerSetup({ isExactIn: true }), ""),
            _makeTakerData(TakerSetup({ isExactIn: false }), ""),
            1 // 1 wei tolerance for rounding
        );
    }
}
