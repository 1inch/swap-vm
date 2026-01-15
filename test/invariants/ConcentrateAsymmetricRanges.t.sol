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
/// @notice Tests XYCConcentrateGrowLiquidity2D with asymmetric price ranges
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

    // ============================================================
    // Safe Price Bounds Calculation
    // ============================================================

    /// @notice Calculate safe priceMin and priceMax for concentrated liquidity
    /// @dev Uses the constraint |α - β| ≤ αβ where α = √(price/priceMin) - 1, β = √(priceMax/price) - 1
    /// @param balanceA Initial balance of token A
    /// @param balanceB Initial balance of token B
    /// @param maxDeltaRatio Maximum allowed delta/balance ratio (e.g., 10e18 means deltaA ≤ 10×balanceA)
    /// @return priceMin Minimum safe price bound
    /// @return priceMax Maximum safe price bound
    /// @return price Current price (balanceB/balanceA)
    function calculateSafePriceBounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 maxDeltaRatio
    ) public pure returns (uint256 priceMin, uint256 priceMax, uint256 price) {
        // Current price = balanceB / balanceA (in 1e18 scale)
        price = balanceB * 1e18 / balanceA;

        // For symmetric bounds with delta ratio = maxDeltaRatio:
        // deltaA/balanceA = 1/α ≤ maxDeltaRatio
        // α ≥ 1/maxDeltaRatio
        // √(price/priceMin) = 1 + α ≥ 1 + 1/maxDeltaRatio
        // price/priceMin = (1 + 1/maxDeltaRatio)² = (maxDeltaRatio + 1)² / maxDeltaRatio²
        // priceMin = price × maxDeltaRatio² / (maxDeltaRatio + 1)²

        // Similarly:
        // priceMax = price × (maxDeltaRatio + 1)² / maxDeltaRatio²

        uint256 numerator = maxDeltaRatio * maxDeltaRatio / 1e18;           // maxDeltaRatio² (scaled)
        uint256 sumPlusOne = maxDeltaRatio + 1e18;
        uint256 denominator = sumPlusOne * sumPlusOne / 1e18;               // (maxDeltaRatio + 1)² (scaled)

        priceMin = price * numerator / denominator;
        priceMax = price * denominator / numerator;
    }

    /// @notice Check if a price range satisfies the safety constraint
    /// @dev Constraint: |α - β| ≤ αβ ensures swaps won't underflow
    function isValidPriceRange(
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (bool valid, uint256 deltaRatioA, uint256 deltaRatioB) {
        if (price < priceMin || price > priceMax) return (false, 0, 0);
        if (price == priceMin || price == priceMax) return (true, 0, 0);

        // α = √(price/priceMin) - 1
        // β = √(priceMax/price) - 1
        uint256 sqrtR = Math.sqrt(price * 1e18 / priceMin) * 1e9;  // √(price/priceMin) in 1e18
        uint256 sqrtS = Math.sqrt(priceMax * 1e18 / price) * 1e9;  // √(priceMax/price) in 1e18

        uint256 alpha = sqrtR - 1e18;  // (√r - 1) in 1e18 scale
        uint256 beta = sqrtS - 1e18;   // (√s - 1) in 1e18 scale

        // Delta ratios
        deltaRatioA = alpha > 0 ? 1e18 * 1e18 / alpha : 0;
        deltaRatioB = beta > 0 ? 1e18 * 1e18 / beta : 0;

        // Check constraint: |α - β| ≤ αβ
        uint256 diff = alpha > beta ? alpha - beta : beta - alpha;
        uint256 product = alpha * beta / 1e18;

        valid = diff <= product;
    }

    /// @notice Implementation of _executeSwap for CoreInvariants
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

    /// @notice Create invariant config for concentrated liquidity tests
    /// @param symmetryTolerance Tolerance for symmetry checks (scales with delta ratio)
    /// @param exactInData Taker data for exactIn swaps
    /// @param exactOutData Taker data for exactOut swaps
    function _createInvariantConfig(
        uint256 symmetryTolerance,
        bytes memory exactInData,
        bytes memory exactOutData
    ) internal pure returns (InvariantConfig memory) {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 10e18;
        amounts[2] = 50e18;

        uint256[] memory emptyAmounts = new uint256[](0);

        return InvariantConfig({
            symmetryTolerance: symmetryTolerance,
            additivityTolerance: symmetryTolerance,  // Allow same tolerance for additivity
            roundingToleranceBps: 100,  // 1%
            monotonicityToleranceBps: 0,  // strict
            testAmounts: amounts,
            testAmountsExactOut: emptyAmounts,
            skipAdditivity: false,
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: exactInData,
            exactOutTakerData: exactOutData
        });
    }

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        taker = address(this);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        tokenA.mint(maker, 1_000_000_000e18);
        tokenB.mint(maker, 1_000_000_000e18);
        tokenA.mint(taker, 1_000_000_000e18);
        tokenB.mint(taker, 1_000_000_000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ============================================================
    // Helper: Create order with GrowLiquidity2D
    // ============================================================

    function _createGrowLiquidityOrder(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
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

        if (balanceA > 0) {
            console.log("deltaA / balanceA:", deltaA * 100 / balanceA, "%");
        }
        if (balanceB > 0) {
            console.log("deltaB / balanceB:", deltaB * 100 / balanceB, "%");
        }

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
                    dynamic([balanceA, balanceB])
                )),
                program.build(
                    XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity)
                ),
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
    // Test: Symmetric Range with Safe Bounds (baseline)
    // ============================================================

    function test_GrowLiquidity_SymmetricRange() public {
        console.log("");
        console.log("=== test_GrowLiquidity_SymmetricRange ===");
        console.log("Baseline test with safe bounds (2.5x delta ratio)");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 2.5e18;  // ~2.5x delta ratio (similar to 0.5-2 range at middle)

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Safe bounds calculated:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with tight tolerance for small delta ratio
        InvariantConfig memory config = _createInvariantConfig(3, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ============================================================
    // Test: Moderate Delta Ratio (10x)
    // ============================================================

    function test_GrowLiquidity_ModerateDeltaRatio() public {
        console.log("");
        console.log("=== test_GrowLiquidity_ModerateDeltaRatio ===");
        console.log("Testing with 10x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 10e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Safe bounds calculated:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with moderate tolerance for 10x delta
        InvariantConfig memory config = _createInvariantConfig(5, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ============================================================
    // Test: Wide Range (50x delta ratio)
    // ============================================================

    function test_GrowLiquidity_WideDeltaRatio() public {
        console.log("");
        console.log("=== test_GrowLiquidity_WideDeltaRatio ===");
        console.log("Testing with 50x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 50e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Safe bounds calculated:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with wider tolerance for 50x delta
        InvariantConfig memory config = _createInvariantConfig(25, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ============================================================
    // Test: Very Wide Range (100x delta ratio)
    // ============================================================

    function test_GrowLiquidity_VeryWideDeltaRatio() public {
        console.log("");
        console.log("=== test_GrowLiquidity_VeryWideDeltaRatio ===");
        console.log("Testing with 100x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 100e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Safe bounds calculated:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with larger tolerance for 100x delta
        InvariantConfig memory config = _createInvariantConfig(50, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ============================================================
    // Test: Extreme but Safe Range (500x delta ratio)
    // ============================================================

    function test_GrowLiquidity_ExtremeDeltaRatio() public {
        console.log("");
        console.log("=== test_GrowLiquidity_ExtremeDeltaRatio ===");
        console.log("Testing with 500x max delta ratio - near practical limit");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 500e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Safe bounds calculated:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with large tolerance for 500x delta
        InvariantConfig memory config = _createInvariantConfig(250, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ============================================================
    // Analysis: Mathematical Breakdown
    // ============================================================

    function test_AnalyzeDeltaFormula() public pure {
        console.log("");
        console.log("=== Mathematical Analysis of Delta Formula ===");
        console.log("");
        console.log("Delta formulas:");
        console.log("  sqrtPriceMin = sqrt(price / priceMin) * 1e9");
        console.log("  sqrtPriceMax = sqrt(priceMax / price) * 1e9");
        console.log("  deltaA = balanceA * 1e18 / (sqrtPriceMin - 1e18)");
        console.log("  deltaB = balanceB * 1e18 / (sqrtPriceMax - 1e18)");
        console.log("");
        console.log("Problem: As price approaches boundary:");
        console.log("  - price -> priceMin: sqrtPriceMin -> 1e18, denominator -> 0, deltaA -> infinity");
        console.log("  - price -> priceMax: sqrtPriceMax -> 1e18, denominator -> 0, deltaB -> infinity");
        console.log("");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        // Test various price positions
        uint256[5] memory prices = [uint256(0.5e18), 0.51e18, 1e18, 1.99e18, 2e18];
        string[5] memory labels = ["at min", "2% above min", "middle", "0.5% below max", "at max"];

        for (uint256 i = 0; i < 5; i++) {
            uint256 price = prices[i];
            if (price < priceMin || price > priceMax) continue;

            (uint256 deltaA, uint256 deltaB, ) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA, balanceB, price, priceMin, priceMax
            );

            console.log("---");
            console.log("Price position:", labels[i]);
            console.log("  deltaA:", deltaA / 1e18, "e18");
            console.log("  deltaB:", deltaB / 1e18, "e18");
            console.log("  deltaA/balance ratio:", deltaA > 0 ? deltaA * 100 / balanceA : 0, "%");
            console.log("  deltaB/balance ratio:", deltaB > 0 ? deltaB * 100 / balanceB : 0, "%");
        }
    }

    // ============================================================
    // Analysis: Where exactly does overflow occur?
    // ============================================================

    function test_AnalyzeOverflowLocation() public view {
        console.log("");
        console.log("=== Analyzing Where Overflow Occurs ===");
        console.log("");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1.99e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (uint256 deltaA, uint256 deltaB, ) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, price, priceMin, priceMax
        );

        uint256 virtualBalanceA = balanceA + deltaA;
        uint256 virtualBalanceB = balanceB + deltaB;

        console.log("Real balances:");
        console.log("  balanceA:", balanceA / 1e18, "e18");
        console.log("  balanceB:", balanceB / 1e18, "e18");
        console.log("");
        console.log("Virtual balances (with deltas):");
        console.log("  virtualBalanceA:", virtualBalanceA / 1e18, "e18");
        console.log("  virtualBalanceB:", virtualBalanceB / 1e18, "e18");
        console.log("");

        // Simulate XYC swap formula
        uint256 amountIn = 10e18;
        uint256 virtualAmountOut = virtualBalanceB * amountIn / (virtualBalanceA + amountIn);

        console.log("XYC Swap calculation (swapping", amountIn / 1e18, "A for B):");
        console.log("  virtualAmountOut = virtualBalanceB * amountIn / (virtualBalanceA + amountIn)");
        console.log("  virtualAmountOut =", virtualAmountOut / 1e18, "e18");
        console.log("");

        console.log("The problem:");
        console.log("  virtualAmountOut:", virtualAmountOut / 1e18, "e18");
        console.log("  realBalanceB:", balanceB / 1e18, "e18");

        if (virtualAmountOut > balanceB) {
            console.log("");
            console.log("  !!! virtualAmountOut > realBalanceB !!!");
            console.log("  Excess:", (virtualAmountOut - balanceB) / 1e18, "e18");
            console.log("");
            console.log("Location of overflow:");
            console.log("  In Balances.sol, when updating real balance:");
            console.log("  newBalanceB = balanceB - amountOut");
            console.log("  This underflows because amountOut > balanceB");
        }
    }

    // ============================================================
    // SAFE BOUNDS TESTS - Using calculated price bounds
    // ============================================================

    function test_SafeBounds_VerifyCalculation() public pure {
        console.log("");
        console.log("=== test_SafeBounds_VerifyCalculation ===");
        console.log("Verify that calculateSafePriceBounds produces valid ranges");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        // Test various max delta ratios
        uint256[4] memory ratios = [uint256(1e18), 2e18, 10e18, 100e18];
        string[4] memory labels = ["1x", "2x", "10x", "100x"];

        for (uint256 i = 0; i < 4; i++) {
            (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
                balanceA, balanceB, ratios[i]
            );

            (bool valid, uint256 deltaRatioA, uint256 deltaRatioB) = isValidPriceRange(price, priceMin, priceMax);

            console.log("---");
            console.log("Max delta ratio:", labels[i]);
            console.log("  price:", price / 1e16, "/ 100");
            console.log("  priceMin:", priceMin / 1e16, "/ 100");
            console.log("  priceMax:", priceMax / 1e16, "/ 100");
            console.log("  range factor:", priceMax * 100 / price, "% of price");
            console.log("  valid:", valid ? "YES" : "NO");
            console.log("  actual deltaRatioA:", deltaRatioA / 1e18, "x");
            console.log("  actual deltaRatioB:", deltaRatioB / 1e18, "x");

            assertTrue(valid, "Calculated bounds should be valid");
        }
    }

    function test_SafeBounds_SymmetricPool_10xDeltaRatio() public {
        console.log("");
        console.log("=== test_SafeBounds_SymmetricPool_10xDeltaRatio ===");
        console.log("Using safe bounds with 10x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 10e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Calculated safe bounds:");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants with reasonable tolerance
        InvariantConfig memory config = _createInvariantConfig(5, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_AsymmetricPool_2to1() public {
        console.log("");
        console.log("=== test_SafeBounds_AsymmetricPool_2to1 ===");
        console.log("Asymmetric pool (2:1 ratio) with safe bounds");

        uint256 balanceA = 2000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 10e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Calculated safe bounds:");
        console.log("  price (B/A):", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants
        InvariantConfig memory config = _createInvariantConfig(5, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_AsymmetricPool_1to10() public {
        console.log("");
        console.log("=== test_SafeBounds_AsymmetricPool_1to10 ===");
        console.log("Highly asymmetric pool (1:10 ratio) with safe bounds");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 10000e18;
        uint256 maxDeltaRatio = 10e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Calculated safe bounds:");
        console.log("  price (B/A):", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Test all invariants
        InvariantConfig memory config = _createInvariantConfig(5, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_LargeSwap() public {
        console.log("");
        console.log("=== test_SafeBounds_LargeSwap ===");
        console.log("Large swap (50% of balance) with safe bounds");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 5e18;  // Tighter ratio for large swaps

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Calculated safe bounds (5x max delta):");
        console.log("  priceMin:", priceMin);
        console.log("  priceMax:", priceMax);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Large swap - 50% of balanceA - test with custom amounts
        uint256[] memory largeAmounts = new uint256[](3);
        largeAmounts[0] = 100e18;
        largeAmounts[1] = 250e18;
        largeAmounts[2] = 500e18;

        uint256[] memory emptyAmounts = new uint256[](0);

        InvariantConfig memory config = InvariantConfig({
            symmetryTolerance: 5,
            additivityTolerance: 5,
            roundingToleranceBps: 100,
            monotonicityToleranceBps: 0,
            testAmounts: largeAmounts,
            testAmountsExactOut: emptyAmounts,
            skipAdditivity: true,  // Skip additivity for large swaps (would drain pool)
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: exactInData,
            exactOutTakerData: exactOutData
        });

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_TightRange_2xDelta() public {
        console.log("");
        console.log("=== test_SafeBounds_TightRange_2xDelta ===");
        console.log("Tight range with 2x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 2e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Tight bounds (2x max delta):");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMin pct of price:", priceMin * 100 / price);
        console.log("  priceMax:", priceMax);
        console.log("  priceMax pct of price:", priceMax * 100 / price);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Tight range should have very good invariant behavior
        InvariantConfig memory config = _createInvariantConfig(3, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_WideRange_100xDelta() public {
        console.log("");
        console.log("=== test_SafeBounds_WideRange_100xDelta ===");
        console.log("Wide range with 100x max delta ratio");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 maxDeltaRatio = 100e18;

        (uint256 priceMin, uint256 priceMax, uint256 price) = calculateSafePriceBounds(
            balanceA, balanceB, maxDeltaRatio
        );

        console.log("Wide bounds (100x max delta):");
        console.log("  price:", price);
        console.log("  priceMin:", priceMin);
        console.log("  priceMin pct of price:", priceMin * 100 / price);
        console.log("  priceMax:", priceMax);
        console.log("  priceMax pct of price:", priceMax * 100 / price);

        (
            ISwapVM.Order memory order,
            bytes memory exactInData,
            bytes memory exactOutData,
            uint256 deltaA,
            uint256 deltaB,
        ) = _createGrowLiquidityOrder(balanceA, balanceB, price, priceMin, priceMax);

        console.log("Delta ratios:");
        console.log("  deltaA/balanceA:", deltaA * 100 / balanceA, "%");
        console.log("  deltaB/balanceB:", deltaB * 100 / balanceB, "%");

        // Wide range will have larger rounding errors
        InvariantConfig memory config = _createInvariantConfig(50, exactInData, exactOutData);
        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SafeBounds_CompareWithUnsafe() public {
        console.log("");
        console.log("=== test_SafeBounds_CompareWithUnsafe ===");
        console.log("Compare safe bounds vs the failing unsafe bounds");

        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        // The failing case had price=1.99, priceMin=0.5, priceMax=2
        uint256 unsafePrice = 1.99e18;
        uint256 unsafePriceMin = 0.5e18;
        uint256 unsafePriceMax = 2e18;

        console.log("UNSAFE bounds (from failing test):");
        console.log("  price:", unsafePrice);
        console.log("  priceMin:", unsafePriceMin);
        console.log("  priceMax:", unsafePriceMax);

        (bool validUnsafe, uint256 deltaRatioA_unsafe, uint256 deltaRatioB_unsafe) =
            isValidPriceRange(unsafePrice, unsafePriceMin, unsafePriceMax);

        console.log("  valid:", validUnsafe ? "YES" : "NO");
        console.log("  deltaRatioA:", deltaRatioA_unsafe / 1e18, "x");
        console.log("  deltaRatioB:", deltaRatioB_unsafe / 1e18, "x");

        // Now calculate safe bounds for the same pool
        console.log("");
        console.log("SAFE bounds (calculated with 10x max delta):");

        // Use balances that give price ≈ 1.99
        uint256 adjBalanceA = 1000e18;
        uint256 adjBalanceB = 1990e18;

        (uint256 safeMin, uint256 safeMax, uint256 safePrice) = calculateSafePriceBounds(
            adjBalanceA, adjBalanceB, 10e18
        );

        console.log("  price:", safePrice);
        console.log("  priceMin:", safeMin);
        console.log("  priceMax:", safeMax);

        (bool validSafe, uint256 deltaRatioA_safe, uint256 deltaRatioB_safe) =
            isValidPriceRange(safePrice, safeMin, safeMax);

        console.log("  valid:", validSafe ? "YES" : "NO");
        console.log("  deltaRatioA:", deltaRatioA_safe / 1e18, "x");
        console.log("  deltaRatioB:", deltaRatioB_safe / 1e18, "x");

        assertTrue(validSafe, "Safe bounds should be valid");
        assertFalse(validUnsafe, "Unsafe bounds should be invalid");
    }
}

