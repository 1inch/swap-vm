// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { XYCConcentratedSwapArgsBuilder } from "../src/instructions/XYCConcentratedSwap.sol";

import { CoreInvariants } from "./invariants/CoreInvariants.t.sol";

/**
 * @title XYCConcentratedSwapTest
 * @notice Comprehensive tests for the unified XYCConcentratedSwap instruction
 * @dev Tests basic functionality, price bound enforcement, invariants, and edge cases
 */
contract XYCConcentratedSwapTest is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        TokenMock(tokenIn).mint(taker, amount * 10);
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order, tokenIn, tokenOut, amount, takerData
        );
        return (actualIn, actualOut);
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    function _createConcentratedSwapOrder(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) internal view returns (ISwapVM.Order memory, bytes memory, bytes memory) {
        return _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, 0);
    }

    function _createConcentratedSwapOrderWithFee(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax,
        uint32 feeBps
    ) internal view returns (ISwapVM.Order memory, bytes memory, bytes memory) {
        (
            uint256 sqrtPriceMin,
            uint256 sqrtPriceMax,
            uint256 sqrtPrice,
            uint256 liquidity
        ) = XYCConcentratedSwapArgsBuilder.computeParams(
            balanceA, balanceB, price, priceMin, priceMax
        );

        console.log("=== Concentrated Swap Parameters ===");
        console.log("balanceA:", balanceA);
        console.log("balanceB:", balanceB);
        console.log("price:", price);
        console.log("feeBps:", feeBps);
        console.log("sqrtPrice:", sqrtPrice);
        console.log("liquidity:", liquidity);

        // Fee is now integrated directly into the instruction
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = program.build(
            _xycConcentratedSwap2D,
            XYCConcentratedSwapArgsBuilder.build2D(
                sqrtPriceMin,
                sqrtPriceMax,
                sqrtPrice,
                liquidity,
                balanceA,
                balanceB,
                feeBps  // Integrated fee parameter
            )
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        
        bytes memory exactInTakerData = _signAndPackTakerData(order, true, 0);
        bytes memory exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        return (order, exactInTakerData, exactOutTakerData);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
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

    // ============================================================
    // Basic Functionality Tests
    // ============================================================

    function test_ExactIn_SymmetricReserves() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        tokenA.mint(taker, 10e18);
        
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10e18, exactInData
        );

        console.log("ExactIn: amountIn =", amountIn, "amountOut =", amountOut);
        
        assertEq(amountIn, 10e18, "AmountIn should match input");
        assertGt(amountOut, 0, "AmountOut should be positive");
        assertLt(amountOut, 10e18, "AmountOut should be less than input at 1:1 price due to concentration");
    }

    function test_ExactOut_SymmetricReserves() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order,, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        tokenA.mint(taker, 100e18);
        
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 5e18, exactOutData
        );

        console.log("ExactOut: amountIn =", amountIn, "amountOut =", amountOut);
        
        assertEq(amountOut, 5e18, "AmountOut should match requested");
        assertGt(amountIn, 0, "AmountIn should be positive");
    }

    function test_BidirectionalSwaps() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Swap A -> B
        tokenA.mint(taker, 10e18);
        (uint256 inAB, uint256 outAB,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10e18, exactInData
        );
        console.log("A->B: in =", inAB, "out =", outAB);

        // Swap B -> A (same order, different direction)
        tokenB.mint(taker, 10e18);
        (uint256 inBA, uint256 outBA,) = swapVM.swap(
            order, address(tokenB), address(tokenA), 10e18, exactInData
        );
        console.log("B->A: in =", inBA, "out =", outBA);

        assertGt(outAB, 0, "A->B output should be positive");
        assertGt(outBA, 0, "B->A output should be positive");
    }

    // ============================================================
    // Price Bound Enforcement Tests
    // ============================================================

    function test_RevertWhen_SwapExceedsLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.99e18;  // Very narrow range (1%)
        uint256 priceMax = 1.01e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        tokenA.mint(taker, 10000e18);
        
        // Large swap should push price below minimum in narrow range
        vm.expectRevert();
        swapVM.swap(order, address(tokenA), address(tokenB), 5000e18, exactInData);
    }

    function test_RevertWhen_SwapExceedsUpperBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.99e18;  // Very narrow range (1%)
        uint256 priceMax = 1.01e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        tokenB.mint(taker, 10000e18);
        
        // Large swap in opposite direction should push price above maximum
        vm.expectRevert();
        swapVM.swap(order, address(tokenB), address(tokenA), 5000e18, exactInData);
    }

    // ============================================================
    // Invariant Tests
    // ============================================================

    function test_SymmetryInvariant_SymmetricReserves() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = exactOutData;
        // Symmetry tolerance for sqrtPrice-based concentrated liquidity
        // Error sources: (1) +1 ceiling in ExactOut to favor maker
        //                (2) Multiple divisions in price calculations
        // At 10e18 amounts: ~2600 wei error (0.000026%)
        config.symmetryTolerance = 3000;

        // Test symmetry for various amounts
        for (uint256 i = 0; i < config.testAmounts.length; i++) {
            assertSymmetryInvariant(
                swapVM,
                order,
                address(tokenA),
                address(tokenB),
                config.testAmounts[i],
                config.symmetryTolerance,
                exactInData,
                exactOutData
            );
        }
    }

    function test_MonotonicityInvariant() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        InvariantConfig memory config = _getDefaultConfig();
        
        assertMonotonicityInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config.testAmounts,
            exactInData
        );
    }

    function test_AdditivityInvariant() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        assertAdditivityInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            2e18,
            exactInData
        );
    }

    // ============================================================
    // Asymmetric Price Range Tests (Previously Failing Cases)
    // ============================================================

    function test_PriceNearLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 510e18;
        uint256 price = 0.51e18;  // Very close to priceMin
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Near boundaries: larger deltas amplify rounding errors
        // Error sources: extreme virtual balance ratios at boundary prices
        // At 10e18 amounts near boundary: ~10000 wei error (0.0001%)
        assertSymmetryInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            10e18,
            10000,
            exactInData,
            exactOutData
        );
    }

    function test_PriceNearUpperBound() public {
        uint256 balanceA = 500e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.99e18;  // Very close to priceMax
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // This was causing overflow before
        // Small swap should work
        tokenA.mint(taker, 1e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        
        console.log("Near upper bound: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0, "Should produce output");
    }

    function test_VeryNarrowRange() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.99e18;  // 1% range
        uint256 priceMax = 1.01e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Small swap should work in narrow range
        tokenA.mint(taker, 1e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        
        console.log("Narrow range: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0, "Should produce output");
    }

    function test_VeryWideRange() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.01e18;  // 100x range
        uint256 priceMax = 100e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = exactOutData;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // ============================================================
    // State Persistence Tests
    // ============================================================

    function test_StateUpdatesAfterSwap() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // First swap
        tokenA.mint(taker, 10e18);
        (uint256 in1, uint256 out1,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10e18, exactInData
        );
        console.log("Swap 1: in =", in1, "out =", out1);

        // Second swap - should use updated state
        tokenA.mint(taker, 10e18);
        (uint256 in2, uint256 out2,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10e18, exactInData
        );
        console.log("Swap 2: in =", in2, "out =", out2);

        // Second swap should get slightly worse rate due to price movement
        assertLe(out2, out1, "Second swap should get equal or worse rate");
    }

    function test_MultipleSequentialSwaps() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        uint256 totalOut = 0;
        
        // Do 5 sequential swaps
        for (uint256 i = 0; i < 5; i++) {
            tokenA.mint(taker, 5e18);
            (, uint256 out,) = swapVM.swap(
                order, address(tokenA), address(tokenB), 5e18, exactInData
            );
            totalOut += out;
            console.log("Swap", i + 1, ": out =", out);
        }

        console.log("Total output from 5 swaps:", totalOut);
        assertGt(totalOut, 0, "Should have positive total output");
    }

    // ============================================================
    // Large/Small Reserves Tests
    // ============================================================

    function test_VeryLargeReserves() public {
        // Whale-sized reserves (1 million tokens each)
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        // Mint enough for maker
        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Large swap (10k tokens)
        tokenA.mint(taker, 10_000e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10_000e18, exactInData
        );
        
        console.log("Large reserves swap: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 10_000e18);
        assertGt(amountOut, 0);
        
        // Symmetry tolerance scales with amount: ~1600 wei per 1e18
        // For 1000e18, tolerance = 1600 * 1000 = 1.6M wei
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            1000e18, 2_000_000, exactInData, exactOutData
        );
    }

    function test_VerySmallReserves() public {
        // Small reserves (1000 tokens each)
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Small swap (1 token)
        tokenA.mint(taker, 1e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        
        console.log("Small reserves swap: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 1e18);
        assertGt(amountOut, 0);

        // Symmetry tolerance: ~1600 wei per 1e18, so for 0.1e18 ~ 160 wei
        // Add some buffer for rounding
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            0.1e18, 1000, exactInData, exactOutData
        );
    }

    function test_TinyReserves() public {
        // Very tiny reserves (just 10 tokens each)
        uint256 balanceA = 10e18;
        uint256 balanceB = 10e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Tiny swap (0.01 tokens)
        tokenA.mint(taker, 0.01e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 0.01e18, exactInData
        );
        
        console.log("Tiny reserves swap: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 0.01e18);
        assertGt(amountOut, 0);
    }

    // ============================================================
    // Various Swap Amounts Tests
    // ============================================================

    function test_VariousSwapAmounts_Small() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Test various small amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 0.001e18;  // 0.001 tokens
        amounts[1] = 0.01e18;   // 0.01 tokens
        amounts[2] = 0.1e18;    // 0.1 tokens
        amounts[3] = 1e18;      // 1 token
        amounts[4] = 10e18;     // 10 tokens

        for (uint256 i = 0; i < amounts.length; i++) {
            tokenA.mint(taker, amounts[i]);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order, address(tokenA), address(tokenB), amounts[i], exactInData
            );
            console.log("Amount", amounts[i] / 1e15, "milli-tokens: out =", amountOut);
            assertEq(amountIn, amounts[i]);
            assertGt(amountOut, 0, "Should produce output for all amounts");
        }
    }

    function test_VariousSwapAmounts_Large() public {
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.1e18;  // Wide range for large swaps
        uint256 priceMax = 10e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Test various large amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100e18;      // 100 tokens
        amounts[1] = 1_000e18;    // 1k tokens
        amounts[2] = 10_000e18;   // 10k tokens
        amounts[3] = 50_000e18;   // 50k tokens
        amounts[4] = 100_000e18;  // 100k tokens

        for (uint256 i = 0; i < amounts.length; i++) {
            tokenA.mint(taker, amounts[i]);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order, address(tokenA), address(tokenB), amounts[i], exactInData
            );
            console.log("Amount", amounts[i] / 1e18, "tokens: out =", amountOut / 1e18);
            assertEq(amountIn, amounts[i]);
            assertGt(amountOut, 0, "Should produce output for all amounts");
        }
    }

    // ============================================================
    // Bidirectional Swaps Tests
    // ============================================================

    function test_AlternatingDirections() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Alternate A->B and B->A swaps
        for (uint256 i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                tokenA.mint(taker, 100e18);
                (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                    order, address(tokenA), address(tokenB), 100e18, exactInData
                );
                console.log("Swap (A->B): in =", amountIn / 1e18);
                console.log("  out =", amountOut / 1e18);
            } else {
                tokenB.mint(taker, 100e18);
                (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                    order, address(tokenB), address(tokenA), 100e18, exactInData
                );
                console.log("Swap (B->A): in =", amountIn / 1e18);
                console.log("  out =", amountOut / 1e18);
            }
        }
    }

    function test_RestorePoolBalance() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // First: large swap A->B (depletes B)
        tokenA.mint(taker, 1000e18);
        (uint256 in1, uint256 out1,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1000e18, exactInData
        );
        console.log("Deplete B: in A =", in1 / 1e18, "out B =", out1 / 1e18);

        // Second: swap B->A to restore balance
        tokenB.mint(taker, out1);
        (uint256 in2, uint256 out2,) = swapVM.swap(
            order, address(tokenB), address(tokenA), out1, exactInData
        );
        console.log("Restore A: in B =", in2 / 1e18, "out A =", out2 / 1e18);

        // After round-trip, should get back less than original (due to price impact)
        console.log("Round-trip loss:", (1000e18 - out2) / 1e15, "milli-tokens");
        assertLt(out2, 1000e18, "Should have slippage on round-trip");
    }

    // ============================================================
    // Pool Imbalance Tests
    // ============================================================

    function test_LargeImbalance_10to1() public {
        // 10:1 imbalance - much more A than B
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 1_000e18;
        uint256 price = 0.1e18;  // B is 10x more valuable
        uint256 priceMin = 0.05e18;
        uint256 priceMax = 0.5e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Swap A for B
        tokenA.mint(taker, 100e18);
        (uint256 in1, uint256 out1,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        console.log("10:1 imbalance A->B: in =", in1, "out =", out1);
        
        // With concentrated liquidity, output can be larger than spot price suggests
        // Just verify we get positive output
        assertGt(out1, 0, "Should produce positive output");

        // Test symmetry with imbalanced reserves
        // Observed error: ~3260 wei for 10e18 swaps in 10:1 imbalanced pool
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 4000, exactInData, exactOutData
        );
    }

    function test_LargeImbalance_1to10() public {
        // 1:10 imbalance - much more B than A
        uint256 balanceA = 1_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 10e18;  // A is 10x more valuable
        uint256 priceMin = 5e18;
        uint256 priceMax = 20e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Swap A for B - small amount relative to reserves
        tokenA.mint(taker, 1e18);
        (uint256 in1, uint256 out1,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        console.log("1:10 imbalance A->B: in =", in1, "out =", out1);
        
        // Just verify positive output
        assertGt(out1, 0, "Should produce positive output");

        // Test symmetry - increase tolerance for high price ratio
        // Observed error: ~5201 wei for 0.5e18 swaps in 1:10 imbalanced pool
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            0.5e18, 6000, exactInData, exactOutData
        );
    }

    function test_ExtremeImbalance_100to1() public {
        // 100:1 imbalance
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 1_000e18;
        uint256 price = 0.01e18;  // B is 100x more valuable
        uint256 priceMin = 0.005e18;
        uint256 priceMax = 0.1e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Small swap in extreme imbalance
        tokenA.mint(taker, 100e18);  // Smaller swap
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        console.log("100:1 imbalance: in =", amountIn, "out =", amountOut);
        
        // With concentration, just verify positive output
        assertGt(amountOut, 0, "Should produce positive output");
    }

    // ============================================================
    // Different Decimals Tests (18 vs 6)
    // ============================================================

    function test_DifferentDecimals_ScaledTo18() public {
        // Test with price ratio of 100:1 (more moderate than ETH/USDC)
        // Simulates scenarios like ETH/SHIB where one token is much cheaper
        
        uint256 balanceA = 100e18;            // 100 "expensive" tokens  
        uint256 balanceB = 10_000e18;         // 10k "cheap" tokens
        uint256 price = 100e18;               // 1 A = 100 B
        uint256 priceMin = 50e18;             // Price range: 50-200
        uint256 priceMax = 200e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Swap 1 A for B
        tokenA.mint(taker, 1e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        
        console.log("Price ratio swap: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 1e18);
        // At price 100, 1 A should give some B (with concentration effects)
        assertGt(amountOut, 0, "Should get positive output");
        
        // Test symmetry with moderate tolerance
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            0.1e18, 10000, exactInData, exactOutData
        );
    }

    function test_DifferentDecimals_BothSmall() public {
        // Both tokens with small amounts (simulating low-decimal tokens)
        uint256 balanceA = 1000e6;   // Like USDC
        uint256 balanceB = 1000e6;   // Like USDT
        uint256 price = 1e18;        // 1:1 stablecoin pair
        uint256 priceMin = 0.99e18;  // Tight range for stablecoins
        uint256 priceMax = 1.01e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Swap small amounts
        tokenA.mint(taker, 1e6);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e6, exactInData
        );
        
        console.log("6-decimal tokens: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 1e6);
        // With tight stablecoin range, should get nearly 1:1
        assertGt(amountOut, 0.9e6, "Should get close to 1:1 for stablecoins");
    }

    // ============================================================
    // Stress Tests
    // ============================================================

    function test_ManyConsecutiveSwaps() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.1e18;
        uint256 priceMax = 10e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // 50 consecutive swaps
        uint256 totalIn = 0;
        uint256 totalOut = 0;
        
        for (uint256 i = 0; i < 50; i++) {
            uint256 amount = 100e18 + (i * 10e18);  // Varying amounts
            tokenA.mint(taker, amount);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order, address(tokenA), address(tokenB), amount, exactInData
            );
            totalIn += amountIn;
            totalOut += amountOut;
        }

        console.log("50 swaps - Total in:", totalIn / 1e18, "Total out:", totalOut / 1e18);
        assertGt(totalOut, 0);
    }

    function test_AlternatingLargeSmallSwaps() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.1e18;
        uint256 priceMax = 10e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Alternate between tiny and large swaps
        uint256[] memory amounts = new uint256[](10);
        amounts[0] = 0.01e18;
        amounts[1] = 1000e18;
        amounts[2] = 0.001e18;
        amounts[3] = 5000e18;
        amounts[4] = 0.1e18;
        amounts[5] = 2000e18;
        amounts[6] = 0.005e18;
        amounts[7] = 3000e18;
        amounts[8] = 0.05e18;
        amounts[9] = 4000e18;

        for (uint256 i = 0; i < amounts.length; i++) {
            tokenA.mint(taker, amounts[i]);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order, address(tokenA), address(tokenB), amounts[i], exactInData
            );
            console.log("Swap in:", amountIn, "out:", amountOut);
            assertGt(amountOut, 0, "All swaps should produce output");
        }
    }

    // ============================================================
    // Edge Case Price Ranges
    // ============================================================

    function test_ExtremelyTightRange() public {
        // 0.1% price range (like stable pools)
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.999e18;
        uint256 priceMax = 1.001e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // In tight range, even small swaps have high capital efficiency
        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("Tight range (0.1%): in =", amountIn / 1e18, "out =", amountOut / 1e18);
        
        // Should get nearly 1:1 due to concentrated liquidity
        assertGt(amountOut, 99e18, "Should get nearly 1:1 in tight range");
    }

    function test_VeryWideRange_1000x() public {
        // 1000x price range
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.001e18;
        uint256 priceMax = 1000e18;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Wide range means less capital efficiency
        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("Wide range (1000x): in =", amountIn / 1e18, "out =", amountOut / 1e18);
        assertGt(amountOut, 0);

        // Observed error: ~2133 wei for 10e18 swaps in very wide range
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 3000, exactInData, exactOutData
        );
    }

    // ============================================================
    // Monotonicity in Various Configurations
    // ============================================================

    function test_Monotonicity_LargeReserves() public {
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100e18;
        amounts[1] = 1000e18;
        amounts[2] = 5000e18;
        amounts[3] = 10000e18;
        amounts[4] = 50000e18;

        assertMonotonicityInvariant(
            swapVM, order, address(tokenA), address(tokenB), amounts, exactInData
        );
    }

    function test_Monotonicity_ImbalancedPool() public {
        uint256 balanceA = 50_000e18;
        uint256 balanceB = 5_000e18;
        uint256 price = 0.1e18;
        uint256 priceMin = 0.05e18;
        uint256 priceMax = 0.5e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 10e18;
        amounts[1] = 50e18;
        amounts[2] = 100e18;
        amounts[3] = 500e18;
        amounts[4] = 1000e18;

        assertMonotonicityInvariant(
            swapVM, order, address(tokenA), address(tokenB), amounts, exactInData
        );
    }

    // ============================================================
    // Additivity in Various Configurations  
    // ============================================================

    function test_Additivity_LargeAmounts() public {
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Test that 10000 in one swap >= 5000 + 5000 in two swaps
        assertAdditivityInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            5000e18, 10000e18, exactInData
        );
    }

    function test_Additivity_SmallAmounts() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // Test additivity with small amounts
        assertAdditivityInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            0.5e18, 1e18, exactInData
        );
    }

    // ============================================================
    // FlatFeeIn Tests - Various Fee Sizes
    // ============================================================

    function test_WithFee_SmallFee_0_1_Percent() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.001e9; // 0.1% fee

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        // Basic swap should work
        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("0.1% fee: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 100e18);
        // With 0.1% fee on input, output should be ~99.9% of no-fee case
        assertGt(amountOut, 0);
        assertLt(amountOut, 100e18); // Less than input due to fee + price impact

        // Test symmetry with fee
        // Observed error: ~786 wei for 10e18 swaps with 0.1% fee
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 1000, exactInData, exactOutData
        );
    }

    function test_WithFee_MediumFee_0_3_Percent() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9; // 0.3% fee (typical AMM)

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("0.3% fee: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 100e18);
        assertGt(amountOut, 0);

        // Test all invariants - fees add rounding in fee solver, increase tolerance
        // Observed error: ~20218 wei for 50e18 swaps with 0.3% fee
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = exactOutData;
        config.symmetryTolerance = 25000;

        assertAllInvariantsWithConfig(
            swapVM, order, address(tokenA), address(tokenB), config
        );
    }

    function test_WithFee_LargeFee_1_Percent() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.01e9; // 1% fee

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("1% fee: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 100e18);
        assertGt(amountOut, 0);

        // Observed error: ~32787 wei for 10e18 swaps with 1% fee
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 35000, exactInData, exactOutData
        );
    }

    function test_WithFee_VeryLargeFee_5_Percent() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.05e9; // 5% fee

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("5% fee: in =", amountIn, "out =", amountOut);
        assertEq(amountIn, 100e18);
        assertGt(amountOut, 0);
        // With 5% fee, output should be noticeably less
        assertLt(amountOut, 96e18);

        // Observed error: ~30610 wei for 10e18 swaps with 5% fee
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 35000, exactInData, exactOutData
        );
    }

    // ============================================================
    // FlatFeeIn with Large/Small Reserves
    // ============================================================

    function test_WithFee_LargeReserves() public {
        uint256 balanceA = 1_000_000e18;
        uint256 balanceB = 1_000_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        // Large swap
        tokenA.mint(taker, 10_000e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10_000e18, exactInData
        );
        
        console.log("Large reserves with fee: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0);

        // Observed error: ~404392 wei for 1000e18 swaps with fee + large reserves
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            1000e18, 500000, exactInData, exactOutData
        );
    }

    function test_WithFee_SmallReserves() public {
        uint256 balanceA = 100e18;
        uint256 balanceB = 100e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        // Small swap
        tokenA.mint(taker, 1e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1e18, exactInData
        );
        
        console.log("Small reserves with fee: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0);

        // Observed error: ~40 wei for 0.1e18 swaps with fee + small reserves
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            0.1e18, 100, exactInData, exactOutData
        );
    }

    // ============================================================
    // FlatFeeIn with Pool Imbalance
    // ============================================================

    function test_WithFee_ImbalancedPool_10to1() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 1_000e18;
        uint256 price = 0.1e18;
        uint256 priceMin = 0.05e18;
        uint256 priceMax = 0.5e18;
        uint32 feeBps = 0.003e9;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("10:1 imbalance with fee: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0);

        // Observed error: ~3638 wei for 10e18 swaps with fee in 10:1 imbalanced pool
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 4000, exactInData, exactOutData
        );
    }

    function test_WithFee_ImbalancedPool_1to10() public {
        uint256 balanceA = 1_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 10e18;
        uint256 priceMin = 5e18;
        uint256 priceMax = 20e18;
        uint32 feeBps = 0.003e9;

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 10e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 10e18, exactInData
        );
        
        console.log("1:10 imbalance with fee: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0);

        // Observed error: ~4186 wei for 1e18 swaps with fee in 1:10 imbalanced pool
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            1e18, 5000, exactInData, exactOutData
        );
    }

    // ============================================================
    // FlatFeeIn with Different Price Ranges
    // ============================================================

    function test_WithFee_NarrowRange() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.99e18;  // 1% range
        uint256 priceMax = 1.01e18;
        uint32 feeBps = 0.0005e9; // 0.05% fee (low fee for stables)

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("Narrow range with fee: in =", amountIn, "out =", amountOut);
        // Concentrated liquidity in narrow range = minimal slippage
        assertGt(amountOut, 99e18);

        // Narrow range amplifies rounding errors in concentrated math
        // Observed error: ~7109096 wei for 10e18 swaps in 1% range
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 8_000_000, exactInData, exactOutData
        );
    }

    function test_WithFee_WideRange() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.01e18;  // 100x range
        uint256 priceMax = 100e18;
        uint32 feeBps = 0.01e9; // 1% fee

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        tokenA.mint(taker, 100e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 100e18, exactInData
        );
        
        console.log("Wide range with fee: in =", amountIn, "out =", amountOut);
        assertGt(amountOut, 0);

        // Observed error: ~2133 wei for 10e18 swaps with fee in wide range
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB), 
            10e18, 3000, exactInData, exactOutData
        );
    }

    // ============================================================
    // FlatFeeIn Invariant Tests
    // ============================================================

    function test_WithFee_Monotonicity() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100e18;
        amounts[1] = 500e18;
        amounts[2] = 1000e18;
        amounts[3] = 5000e18;
        amounts[4] = 10000e18;

        assertMonotonicityInvariant(
            swapVM, order, address(tokenA), address(tokenB), amounts, exactInData
        );
    }

    function test_WithFee_Additivity() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        // FlatFeeIn maintains additivity (unlike FlatFeeOut)
        assertAdditivityInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            500e18, 1000e18, exactInData
        );
    }

    // ============================================================
    // FlatFeeIn - Multiple Swaps (Fee Accumulation)
    // ============================================================

    function test_WithFee_MultipleSwaps() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        uint256 totalIn = 0;
        uint256 totalOut = 0;
        
        for (uint256 i = 0; i < 10; i++) {
            tokenA.mint(taker, 100e18);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order, address(tokenA), address(tokenB), 100e18, exactInData
            );
            totalIn += amountIn;
            totalOut += amountOut;
        }

        console.log("10 swaps with fee: total in =", totalIn);
        console.log("10 swaps with fee: total out =", totalOut);
        assertGt(totalOut, 0);
        // Due to fees and slippage, output should be less than input
        assertLt(totalOut, totalIn);
    }

    function test_WithFee_BidirectionalSwaps() public {
        uint256 balanceA = 100_000e18;
        uint256 balanceB = 100_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.003e9;

        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);

        (ISwapVM.Order memory order, bytes memory exactInData,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        // Swap A -> B
        tokenA.mint(taker, 1000e18);
        (uint256 in1, uint256 out1,) = swapVM.swap(
            order, address(tokenA), address(tokenB), 1000e18, exactInData
        );
        console.log("A->B with fee: in =", in1, "out =", out1);

        // Swap B -> A (opposite direction)
        tokenB.mint(taker, out1);
        (uint256 in2, uint256 out2,) = swapVM.swap(
            order, address(tokenB), address(tokenA), out1, exactInData
        );
        console.log("B->A with fee: in =", in2, "out =", out2);

        // Round trip should result in less than original due to fees
        assertLt(out2, 1000e18, "Round trip should lose tokens to fees");
        console.log("Round trip loss with fees:", (1000e18 - out2) / 1e15, "milli-tokens");
    }

    // ============================================================
    // FlatFeeIn - Compare Fee Impact
    // ============================================================

    function test_CompareFeeImpact() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        // No fee order
        (ISwapVM.Order memory orderNoFee, bytes memory exactInNoFee,) = 
            _createConcentratedSwapOrder(balanceA, balanceB, price, priceMin, priceMax);

        // 0.3% fee order
        (ISwapVM.Order memory order03, bytes memory exactIn03,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, 0.003e9);

        // 1% fee order
        (ISwapVM.Order memory order1, bytes memory exactIn1,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, 0.01e9);

        // 5% fee order
        (ISwapVM.Order memory order5, bytes memory exactIn5,) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, 0.05e9);

        uint256 swapAmount = 100e18;

        tokenA.mint(taker, swapAmount);
        (, uint256 outNoFee,) = swapVM.swap(orderNoFee, address(tokenA), address(tokenB), swapAmount, exactInNoFee);

        tokenA.mint(taker, swapAmount);
        (, uint256 out03,) = swapVM.swap(order03, address(tokenA), address(tokenB), swapAmount, exactIn03);

        tokenA.mint(taker, swapAmount);
        (, uint256 out1,) = swapVM.swap(order1, address(tokenA), address(tokenB), swapAmount, exactIn1);

        tokenA.mint(taker, swapAmount);
        (, uint256 out5,) = swapVM.swap(order5, address(tokenA), address(tokenB), swapAmount, exactIn5);

        console.log("=== Fee Impact Comparison ===");
        console.log("No fee output:", outNoFee);
        console.log("0.3% fee output:", out03);
        console.log("  reduction (bps):", (outNoFee - out03) * 10000 / outNoFee);
        console.log("1% fee output:", out1);
        console.log("  reduction (bps):", (outNoFee - out1) * 10000 / outNoFee);
        console.log("5% fee output:", out5);
        console.log("  reduction (bps):", (outNoFee - out5) * 10000 / outNoFee);

        // Verify fee ordering
        assertGt(outNoFee, out03, "No fee should give more than 0.3%");
        assertGt(out03, out1, "0.3% fee should give more than 1%");
        assertGt(out1, out5, "1% fee should give more than 5%");
    }

    // ============================================================
    // FlatFeeIn - All Invariants With Fees
    // ============================================================

    function test_WithFee_AllInvariants_SmallFee() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.001e9; // 0.1%

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = exactOutData;
        // Observed error: ~30836 wei for 1e18 swaps with 0.1% fee
        config.symmetryTolerance = 35000;

        assertAllInvariantsWithConfig(
            swapVM, order, address(tokenA), address(tokenB), config
        );
    }

    function test_WithFee_AllInvariants_LargeFee() public {
        uint256 balanceA = 10_000e18;
        uint256 balanceB = 10_000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 feeBps = 0.02e9; // 2%

        (ISwapVM.Order memory order, bytes memory exactInData, bytes memory exactOutData) = 
            _createConcentratedSwapOrderWithFee(balanceA, balanceB, price, priceMin, priceMax, feeBps);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = exactOutData;
        // Observed error: ~14840 wei for 10e18 swaps with 2% fee
        config.symmetryTolerance = 15000;

        assertAllInvariantsWithConfig(
            swapVM, order, address(tokenA), address(tokenB), config
        );
    }
}

