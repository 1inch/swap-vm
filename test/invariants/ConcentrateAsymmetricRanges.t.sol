// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { CoreInvariants } from "./CoreInvariants.t.sol";

/// @title ConcentrateAsymmetricRanges
/// @notice Tests XYCConcentrate instructions with asymmetric price ranges
/// @dev Investigates edge cases when price is near boundaries
contract ConcentrateAsymmetricRanges is Test, OpcodesDebug, CoreInvariants {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker;

    /// @notice Implementation of _executeSwap for CoreInvariants
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Mint the input tokens (taker is address(this))
        TokenMock(tokenIn).mint(taker, amount * 10);

        // Execute the swap (no prank needed - taker is address(this))
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        taker = address(this);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Large initial balances
        tokenA.mint(maker, 1_000_000_000e18);
        tokenB.mint(maker, 1_000_000_000e18);
        tokenA.mint(taker, 1_000_000_000e18);
        tokenB.mint(taker, 1_000_000_000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        // taker is address(this), so no prank needed
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    function _createOrder(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax,
        bool useGrowLiquidity
    ) internal view returns (
        ISwapVM.Order memory order,
        bytes memory exactInData,
        bytes memory exactOutData,
        uint256 deltaA,
        uint256 deltaB,
        uint256 liquidity
    ) {
        (deltaA, deltaB, liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, price, priceMin, priceMax
        );

        console.log("=== Delta Analysis ===");
        console.log("balanceA:", balanceA);
        console.log("balanceB:", balanceB);
        console.log("price:", price);
        console.log("priceMin:", priceMin);
        console.log("priceMax:", priceMax);
        console.log("deltaA:", deltaA);
        console.log("deltaB:", deltaB);
        console.log("liquidity:", liquidity);
        console.log("deltaA / balanceA ratio:", deltaA > 0 ? deltaA * 100 / balanceA : 0, "%");
        console.log("deltaB / balanceB ratio:", deltaB > 0 ? deltaB * 100 / balanceB : 0, "%");

        Program memory program = ProgramBuilder.init(_opcodes());
        
        bytes memory concentrateInstruction;
        if (useGrowLiquidity) {
            concentrateInstruction = program.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity)
            );
        } else {
            concentrateInstruction = program.build(
                XYCConcentrate._xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity)
            );
        }

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
                    dynamic([balanceA, balanceB])
                )),
                concentrateInstruction,
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        exactInData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
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
            signature: signature
        }));

        exactOutData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: false,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(type(uint256).max),
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

    // ============================================================
    // Delta Computation Analysis Tests
    // ============================================================

    /// @notice Analyze delta values for various price positions
    function test_AnalyzeDeltaComputation() public pure {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("=== Delta Computation Analysis ===");
        console.log("Symmetric range: priceMin=0.5, priceMax=2.0");
        console.log("");

        // Test various price positions
        uint256[] memory prices = new uint256[](5);
        prices[0] = 0.5e18;   // At priceMin
        prices[1] = 0.6e18;   // Near priceMin
        prices[2] = 1e18;     // Middle
        prices[3] = 1.9e18;   // Near priceMax
        prices[4] = 2e18;     // At priceMax

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 price = prices[i];
            (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA, balanceB, price, priceMin, priceMax
            );
            
            console.log("---");
            console.log("Price:", price / 1e16, "/ 100");
            console.log("deltaA:", deltaA);
            console.log("deltaB:", deltaB);
            console.log("liquidity:", liquidity);
        }
    }

    /// @notice Analyze extreme asymmetric ranges
    function test_AnalyzeExtremeAsymmetricRanges() public pure {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        console.log("=== Extreme Asymmetric Range Analysis ===");
        
        // Case 1: Price very close to priceMin
        {
            uint256 price = 0.51e18;
            uint256 priceMin = 0.5e18;
            uint256 priceMax = 2e18;
            
            console.log("");
            console.log("Case 1: Price near lower bound (0.51 in [0.5, 2.0])");
            
            (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA, balanceB, price, priceMin, priceMax
            );
            
            console.log("deltaA:", deltaA);
            console.log("deltaB:", deltaB);
            console.log("deltaA/balanceA:", deltaA / balanceA);
            console.log("Observation: deltaA is very large when price is close to priceMin");
        }

        // Case 2: Price very close to priceMax
        {
            uint256 price = 1.99e18;
            uint256 priceMin = 0.5e18;
            uint256 priceMax = 2e18;
            
            console.log("");
            console.log("Case 2: Price near upper bound (1.99 in [0.5, 2.0])");
            
            (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA, balanceB, price, priceMin, priceMax
            );
            
            console.log("deltaA:", deltaA);
            console.log("deltaB:", deltaB);
            console.log("deltaB/balanceB:", deltaB / balanceB);
            console.log("Observation: deltaB is very large when price is close to priceMax");
        }

        // Case 3: Extremely asymmetric - price 1% above priceMin
        {
            uint256 price = 1.01e18;
            uint256 priceMin = 1e18;
            uint256 priceMax = 10e18;
            
            console.log("");
            console.log("Case 3: Extremely close to lower bound (1.01 in [1.0, 10.0])");
            
            (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA, balanceB, price, priceMin, priceMax
            );
            
            console.log("deltaA:", deltaA);
            console.log("deltaB:", deltaB);
            console.log("deltaA/balanceA:", deltaA / balanceA);
        }
    }

    // ============================================================
    // GrowPriceRange2D Tests with Asymmetric Ranges
    // ============================================================

    function test_GrowPriceRange_PriceNearLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 0.51e18;     // Very close to priceMin
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("");
        console.log("=== test_GrowPriceRange_PriceNearLowerBound ===");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, false);

        // Test a small swap
        uint256 swapAmount = 10e18;
        
        console.log("");
        console.log("=== Swap Test ===");
        console.log("Swap amount:", swapAmount);

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // Test symmetry with default tolerance (2 wei)
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    function test_GrowPriceRange_PriceNearUpperBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.99e18;     // Very close to priceMax
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("");
        console.log("=== test_GrowPriceRange_PriceNearUpperBound ===");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, false);

        // Test a small swap
        uint256 swapAmount = 10e18;
        
        console.log("");
        console.log("=== Swap Test ===");
        console.log("Swap amount:", swapAmount);

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // Test symmetry
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    // ============================================================
    // GrowLiquidity2D Tests with Asymmetric Ranges
    // ============================================================

    function test_GrowLiquidity_PriceNearLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 0.51e18;     // Very close to priceMin
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("");
        console.log("=== test_GrowLiquidity_PriceNearLowerBound ===");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, true);

        // Test a small swap
        uint256 swapAmount = 10e18;
        
        console.log("");
        console.log("=== Swap Test ===");
        console.log("Swap amount:", swapAmount);

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // Test symmetry with default tolerance (2 wei)
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    function test_GrowLiquidity_PriceNearUpperBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.99e18;     // Very close to priceMax
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("");
        console.log("=== test_GrowLiquidity_PriceNearUpperBound ===");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, true);

        // Test a small swap
        uint256 swapAmount = 10e18;
        
        console.log("");
        console.log("=== Swap Test ===");
        console.log("Swap amount:", swapAmount);

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // Test symmetry
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    // ============================================================
    // Extremely Asymmetric Cases
    // ============================================================

    function test_GrowLiquidity_ExtremelyCloseToLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.005e18;    // Only 0.5% above priceMin
        uint256 priceMin = 1e18;
        uint256 priceMax = 10e18;

        console.log("");
        console.log("=== test_GrowLiquidity_ExtremelyCloseToLowerBound ===");
        console.log("Price is only 0.5% above priceMin");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, true);

        uint256 swapAmount = 10e18;

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("");
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // This may fail with symmetry violation due to extreme delta values
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    function test_GrowLiquidity_ExtremelyCloseToUpperBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 9.95e18;     // Only 0.5% below priceMax
        uint256 priceMin = 1e18;
        uint256 priceMax = 10e18;

        console.log("");
        console.log("=== test_GrowLiquidity_ExtremelyCloseToUpperBound ===");
        console.log("Price is only 0.5% below priceMax");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, true);

        uint256 swapAmount = 10e18;

        // Quote exactIn
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("");
        console.log("ExactIn quote: in =", amountIn, "out =", amountOut);

        // This may fail with arithmetic overflow when amountOut > balanceB
        assertSymmetryInvariant(
            swapVM, order, address(tokenA), address(tokenB),
            swapAmount, 2, exactInData, exactOutData
        );
    }

    // ============================================================
    // Analysis: Compare Virtual vs Real Balances
    // ============================================================

    /// @notice Test real swap execution near upper bound - should overflow
    function test_GrowLiquidity_RealSwap_NearUpperBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 9.95e18;     // Only 0.5% below priceMax
        uint256 priceMin = 1e18;
        uint256 priceMax = 10e18;

        console.log("");
        console.log("=== test_GrowLiquidity_RealSwap_NearUpperBound ===");
        console.log("This test executes a REAL swap (not just quote)");
        console.log("When amountOut > realBalanceB, the swap should fail");

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            ,
            uint256 deltaA,
            uint256 deltaB,
            uint256 liquidity
        ) = _createOrder(balanceA, balanceB, price, priceMin, priceMax, true);

        uint256 swapAmount = 10e18;

        // Quote first to see expected output
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("");
        console.log("Quoted amountOut:", quotedOut);
        console.log("Real balanceB:", balanceB);
        
        if (quotedOut > balanceB) {
            console.log("!!! quotedOut > balanceB - real swap will fail !!!");
        }

        // Try to execute real swap
        tokenA.mint(taker, swapAmount);
        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order, address(tokenA), address(tokenB), swapAmount, exactInData
        );
        console.log("Actual swap: in =", actualIn, "out =", actualOut);
    }

    function test_AnalyzeVirtualVsRealBalances() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.99e18;     // Near upper bound
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        console.log("");
        console.log("=== Virtual vs Real Balance Analysis ===");
        console.log("When price is near priceMax, deltaB becomes very large");
        console.log("This means virtualBalanceB >> realBalanceB");
        console.log("");

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, price, priceMin, priceMax
        );

        uint256 virtualBalanceA = balanceA + deltaA;
        uint256 virtualBalanceB = balanceB + deltaB;

        console.log("Real balanceA:", balanceA);
        console.log("Real balanceB:", balanceB);
        console.log("deltaA:", deltaA);
        console.log("deltaB:", deltaB);
        console.log("Virtual balanceA:", virtualBalanceA);
        console.log("Virtual balanceB:", virtualBalanceB);
        console.log("");

        // Calculate what happens with a swap
        // XYC formula: amountOut = balanceOut * amountIn / (balanceIn + amountIn)
        uint256 amountIn = 10e18;
        uint256 virtualAmountOut = virtualBalanceB * amountIn / (virtualBalanceA + amountIn);
        
        console.log("If we swap", amountIn, "A for B:");
        console.log("Virtual amountOut (from XYC):", virtualAmountOut);
        console.log("Real balanceB:", balanceB);
        
        if (virtualAmountOut > balanceB) {
            console.log("");
            console.log("!!! PROBLEM: virtualAmountOut > realBalanceB !!!");
            console.log("The swap would try to send more B than the pool has");
            console.log("This causes arithmetic underflow in balance update");
        }
    }
}

