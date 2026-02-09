// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Test for computing price bounds from deltas
contract ComputePriceBoundsTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant SQRT_ONE = 1e9;

    struct PriceBounds {
        uint256 priceMin;
        uint256 priceMax;
    }

    /// @notice Compute priceMin/priceMax from deltas and balances for a pair
    /// @param price Absolute price (use 1e18 for 1:1 like Uniswap V3, or balanceB/balanceA for current)
    function computePriceBounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 deltaA,
        uint256 deltaB,
        uint256 price
    ) public pure returns (PriceBounds memory bounds) {
        // From formula: deltaA = balanceA / (sqrt(price/priceMin) - 1)
        // => sqrt(price/priceMin) = (balanceA + deltaA) / deltaA
        // => priceMin = price * (deltaA / (balanceA + deltaA))²

        uint256 concentrated_A = balanceA + deltaA;
        uint256 ratio_A = deltaA * ONE / concentrated_A;
        bounds.priceMin = price * ratio_A / ONE * ratio_A / ONE;

        // From formula: deltaB = balanceB / (sqrt(priceMax/price) - 1)
        // => sqrt(priceMax/price) = (balanceB + deltaB) / deltaB
        // => priceMax = price * ((balanceB + deltaB) / deltaB)²

        uint256 concentrated_B = balanceB + deltaB;
        uint256 ratio_B = concentrated_B * ONE / deltaB;
        bounds.priceMax = price * ratio_B / ONE * ratio_B / ONE;
    }

    function computeDeltas(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (uint256 deltaA, uint256 deltaB, uint256 liquidity) {
        uint256 sqrtPriceMin = Math.sqrt(price * ONE / priceMin) * SQRT_ONE;
        uint256 sqrtPriceMax = Math.sqrt(priceMax * ONE / price) * SQRT_ONE;
        deltaA = (price == priceMin) ? 0 : (balanceA * ONE / (sqrtPriceMin - ONE));
        deltaB = (price == priceMax) ? 0 : (balanceB * ONE / (sqrtPriceMax - ONE));
        liquidity = Math.sqrt((balanceA + deltaA) * (balanceB + deltaB));
    }

    function test_ComputePriceBounds_EqualBalancesDifferentDeltas() public {
        emit log_string("=== Test: Equal Balances, Different Deltas ===");

        uint256 balanceA = 150 * ONE;
        uint256 balanceB = 200 * ONE;
        uint256 balanceC = 300 * ONE;

        uint256 deltaA = 100 * ONE;
        uint256 deltaB = 200 * ONE;
        uint256 deltaC = 150 * ONE;

        emit log_string("\n--- Input Balances ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        emit log_string("\n--- Input Deltas ---");
        emit log_named_decimal_uint("deltaA", deltaA, 18);
        emit log_named_decimal_uint("deltaB", deltaB, 18);
        emit log_named_decimal_uint("deltaC", deltaC, 18);

        // Compute bounds for pair A/B
        PriceBounds memory bounds_AB = computePriceBounds(balanceA, balanceB, deltaA, deltaB, balanceB * ONE / balanceA);
        emit log_string("\n--- Pair A/B ---");
        emit log_named_decimal_uint("priceMin_AB", bounds_AB.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AB", bounds_AB.priceMax, 18);
        uint256 range_AB = bounds_AB.priceMax * ONE / bounds_AB.priceMin;
        emit log_named_decimal_uint("range_AB (x)", range_AB / 1e18, 0);

        (uint256 deltaACalced, uint256 deltaBCalced, uint256 liquidity) = computeDeltas(balanceA, balanceB, balanceB * ONE / balanceA, bounds_AB.priceMin, bounds_AB.priceMax);
        emit log_string("\n--- Pair A/B Deltas & Liquidity ---");
        emit log_named_decimal_uint("deltaA (from formula)", deltaACalced, 18);
        emit log_named_decimal_uint("deltaB (from formula)", deltaBCalced, 18);
        emit log_named_decimal_uint("liquidity (L)", liquidity, 18);

        // Compute bounds for pair A/C
        PriceBounds memory bounds_AC = computePriceBounds(balanceA, balanceC, deltaA, deltaC, balanceC * ONE / balanceA);
        emit log_string("\n--- Pair A/C ---");
        emit log_named_decimal_uint("priceMin_AC", bounds_AC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC", bounds_AC.priceMax, 18);
        uint256 range_AC = bounds_AC.priceMax * ONE / bounds_AC.priceMin;
        emit log_named_decimal_uint("range_AC (x)", range_AC / 1e18, 0);

        uint256 deltaCCalced;
        (deltaACalced, deltaCCalced, liquidity) = computeDeltas(balanceA, balanceC, balanceC * ONE / balanceA, bounds_AC.priceMin, bounds_AC.priceMax);
        emit log_string("\n--- Pair A/C Deltas & Liquidity ---");
        emit log_named_decimal_uint("deltaA (from formula)", deltaACalced, 18);
        emit log_named_decimal_uint("deltaC (from formula)", deltaCCalced, 18);
        emit log_named_decimal_uint("liquidity (L)", liquidity, 18);

        // Compute bounds for pair B/C
        PriceBounds memory bounds_BC = computePriceBounds(balanceB, balanceC, deltaB, deltaC, balanceC * ONE / balanceB);
        emit log_string("\n--- Pair B/C ---");
        emit log_named_decimal_uint("priceMin_BC", bounds_BC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_BC", bounds_BC.priceMax, 18);
        uint256 range_BC = bounds_BC.priceMax * ONE / bounds_BC.priceMin;
        emit log_named_decimal_uint("range_BC (x)", range_BC / 1e18, 0);

        (deltaBCalced, deltaCCalced, liquidity) = computeDeltas(balanceB, balanceC, balanceC * ONE / balanceB, bounds_BC.priceMin, bounds_BC.priceMax);
        emit log_string("\n--- Pair B/C Deltas & Liquidity ---");
        emit log_named_decimal_uint("deltaB (from formula)", deltaBCalced, 18);
        emit log_named_decimal_uint("deltaC (from formula)", deltaCCalced, 18);
        emit log_named_decimal_uint("liquidity (L)", liquidity, 18);

        emit log_string("\n=== Summary ===");
        emit log_string("Different deltas -> Different concentration ranges");
        emit log_named_uint("A/B range multiplier", range_AB / 1e18);
        emit log_named_uint("A/C range multiplier", range_AC / 1e18);
        emit log_named_uint("B/C range multiplier", range_BC / 1e18);
    }

    function test_ComputePriceBounds_EqualDeltas() public {
        emit log_string("=== Test: Equal Balances, Equal Deltas ===");

        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 100 * ONE;
        uint256 balanceC = 100 * ONE;

        uint256 delta = 100 * ONE;  // Same delta for all

        emit log_string("\n--- Input ---");
        emit log_named_decimal_uint("balance (all)", balanceA, 18);
        emit log_named_decimal_uint("delta (all)", delta, 18);

        // Compute bounds for all pairs
        PriceBounds memory bounds_AB = computePriceBounds(balanceA, balanceB, delta, delta, balanceB * ONE / balanceA);
        PriceBounds memory bounds_AC = computePriceBounds(balanceA, balanceC, delta, delta, balanceC * ONE / balanceA);
        PriceBounds memory bounds_BC = computePriceBounds(balanceB, balanceC, delta, delta, balanceC * ONE / balanceB);

        emit log_string("\n--- Results ---");
        emit log_named_decimal_uint("priceMin_AB", bounds_AB.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AB", bounds_AB.priceMax, 18);
        emit log_named_decimal_uint("priceMin_AC", bounds_AC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC", bounds_AC.priceMax, 18);
        emit log_named_decimal_uint("priceMin_BC", bounds_BC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_BC", bounds_BC.priceMax, 18);

        emit log_string("\n=== Summary ===");
        emit log_string("Equal deltas -> All pairs have SAME concentration range!");

        // Verify all are equal
        assertEq(bounds_AB.priceMin, bounds_AC.priceMin, "priceMin should be equal");
        assertEq(bounds_AB.priceMin, bounds_BC.priceMin, "priceMin should be equal");
        assertEq(bounds_AB.priceMax, bounds_AC.priceMax, "priceMax should be equal");
        assertEq(bounds_AB.priceMax, bounds_BC.priceMax, "priceMax should be equal");
    }

    /// @notice Solve for 3 deltas given balances and price ranges for all pairs
    /// @dev This is an over-determined system (6 constraints, 3 unknowns)
    /// We solve it by finding deltas that approximately satisfy all constraints
    function test_ComputeDeltas_FromThreePairRanges() public {
        emit log_string("=== Test: Compute 3 Deltas from Price Ranges ===");

        // Given: balances for 3 tokens
        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 150 * ONE;
        uint256 balanceC = 200 * ONE;

        // Given: desired price ranges for all 3 pairs
        // Let's try with ranges that are compatible
        uint256 priceMin_AB = ONE / 4;
        uint256 priceMax_AB = 4 * ONE;

        uint256 priceMin_AC = ONE / 3;
        uint256 priceMax_AC = 6 * ONE;

        uint256 priceMin_BC = ONE / 2;
        uint256 priceMax_BC = 4 * ONE;

        emit log_string("\n--- Input Balances ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        emit log_string("\n--- Desired Price Ranges ---");
        emit log_named_decimal_uint("priceMin_AB", priceMin_AB, 18);
        emit log_named_decimal_uint("priceMax_AB", priceMax_AB, 18);
        emit log_named_decimal_uint("priceMin_AC", priceMin_AC, 18);
        emit log_named_decimal_uint("priceMax_AC", priceMax_AC, 18);
        emit log_named_decimal_uint("priceMin_BC", priceMin_BC, 18);
        emit log_named_decimal_uint("priceMax_BC", priceMax_BC, 18);

        // Compute current prices
        uint256 price_AB = balanceB * ONE / balanceA;
        uint256 price_AC = balanceC * ONE / balanceA;
        uint256 price_BC = balanceC * ONE / balanceB;

        // Compute deltas for each pair independently
        (uint256 deltaA_from_AB, uint256 deltaB_from_AB,) = computeDeltas(
            balanceA, balanceB, price_AB, priceMin_AB, priceMax_AB
        );

        (uint256 deltaA_from_AC, uint256 deltaC_from_AC,) = computeDeltas(
            balanceA, balanceC, price_AC, priceMin_AC, priceMax_AC
        );

        (uint256 deltaB_from_BC, uint256 deltaC_from_BC,) = computeDeltas(
            balanceB, balanceC, price_BC, priceMin_BC, priceMax_BC
        );

        emit log_string("\n--- Deltas from Pair A/B ---");
        emit log_named_decimal_uint("deltaA (from A/B)", deltaA_from_AB, 18);
        emit log_named_decimal_uint("deltaB (from A/B)", deltaB_from_AB, 18);

        emit log_string("\n--- Deltas from Pair A/C ---");
        emit log_named_decimal_uint("deltaA (from A/C)", deltaA_from_AC, 18);
        emit log_named_decimal_uint("deltaC (from A/C)", deltaC_from_AC, 18);

        emit log_string("\n--- Deltas from Pair B/C ---");
        emit log_named_decimal_uint("deltaB (from B/C)", deltaB_from_BC, 18);
        emit log_named_decimal_uint("deltaC (from B/C)", deltaC_from_BC, 18);

        emit log_string("\n=== Analysis ===");

        // Check consistency for deltaA
        emit log_string("\nDelta A consistency:");
        emit log_named_decimal_uint("deltaA from A/B", deltaA_from_AB, 18);
        emit log_named_decimal_uint("deltaA from A/C", deltaA_from_AC, 18);
        bool deltaA_consistent = deltaA_from_AB == deltaA_from_AC;
        emit log_named_string("Consistent?", deltaA_consistent ? "YES" : "NO");

        // Check consistency for deltaB
        emit log_string("\nDelta B consistency:");
        emit log_named_decimal_uint("deltaB from A/B", deltaB_from_AB, 18);
        emit log_named_decimal_uint("deltaB from B/C", deltaB_from_BC, 18);
        bool deltaB_consistent = deltaB_from_AB == deltaB_from_BC;
        emit log_named_string("Consistent?", deltaB_consistent ? "YES" : "NO");

        // Check consistency for deltaC
        emit log_string("\nDelta C consistency:");
        emit log_named_decimal_uint("deltaC from A/C", deltaC_from_AC, 18);
        emit log_named_decimal_uint("deltaC from B/C", deltaC_from_BC, 18);
        bool deltaC_consistent = deltaC_from_AC == deltaC_from_BC;
        emit log_named_string("Consistent?", deltaC_consistent ? "YES" : "NO");

        if (deltaA_consistent && deltaB_consistent && deltaC_consistent) {
            emit log_string("\n=== SUCCESS: System is consistent! ===");
            emit log_string("Final deltas:");
            emit log_named_decimal_uint("deltaA", deltaA_from_AB, 18);
            emit log_named_decimal_uint("deltaB", deltaB_from_AB, 18);
            emit log_named_decimal_uint("deltaC", deltaC_from_AC, 18);
        } else {
            emit log_string("\n=== WARNING: System is over-constrained! ===");
            emit log_string("Cannot find unique deltas that satisfy all 3 pair ranges.");
            emit log_string("This means the specified price ranges are incompatible.");
        }
    }

    /// @notice Compute all deltas from 3 specific price bounds (one per delta)
    /// @dev Uses priceMin_AB for deltaA, priceMax_AB for deltaB, priceMax_AC for deltaC
    /// @param price_AB Absolute price for A/B pair (use 1e18 for 1:1 like Uniswap V3)
    /// @param price_AC Absolute price for A/C pair (use 1e18 for 1:1 like Uniswap V3)
    /// @param price_BC Absolute price for B/C pair (use 1e18 for 1:1 like Uniswap V3)
    function computeAllDeltasFrom3Bounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 balanceC,
        uint256 price_AB,
        uint256 price_AC,
        uint256 price_BC,
        uint256 priceMin_AB,
        uint256 priceMax_AB,
        uint256 priceMax_AC
    ) public pure returns (
        uint256 deltaA,
        uint256 deltaB,
        uint256 deltaC,
        PriceBounds memory bounds_AB,
        PriceBounds memory bounds_AC,
        PriceBounds memory bounds_BC
    ) {
        // Compute deltaA from priceMin_AB
        uint256 sqrtPriceMin_AB = Math.sqrt(price_AB * ONE / priceMin_AB) * SQRT_ONE;
        deltaA = (price_AB == priceMin_AB) ? 0 : (balanceA * ONE / (sqrtPriceMin_AB - ONE));

        // Compute deltaB from priceMax_AB
        uint256 sqrtPriceMax_AB = Math.sqrt(priceMax_AB * ONE / price_AB) * SQRT_ONE;
        deltaB = (price_AB == priceMax_AB) ? 0 : (balanceB * ONE / (sqrtPriceMax_AB - ONE));

        // Compute deltaC from priceMax_AC
        uint256 sqrtPriceMax_AC = Math.sqrt(priceMax_AC * ONE / price_AC) * SQRT_ONE;
        deltaC = (price_AC == priceMax_AC) ? 0 : (balanceC * ONE / (sqrtPriceMax_AC - ONE));

        // Now compute all price bounds from the deltas
        bounds_AB = computePriceBounds(balanceA, balanceB, deltaA, deltaB, price_AB);
        bounds_AC = computePriceBounds(balanceA, balanceC, deltaA, deltaC, price_AC);
        bounds_BC = computePriceBounds(balanceB, balanceC, deltaB, deltaC, price_BC);
    }

    function test_ComputeAllDeltas_From3Bounds() public {
        emit log_string("=== Test: Compute All Deltas from 3 Specific Bounds ===");

        // Given: balances
        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 150 * ONE;
        uint256 balanceC = 200 * ONE;

        emit log_string("\n--- Input Balances ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Given: 3 price bounds (one per delta)
        uint256 priceMin_AB = ONE / 4;  // 0.25
        uint256 priceMax_AB = 4 * ONE;
        uint256 priceMax_AC = 6 * ONE;

        emit log_string("\n--- Input: 3 Price Bounds ---");
        emit log_named_decimal_uint("priceMin_AB (determines deltaA)", priceMin_AB, 18);
        emit log_named_decimal_uint("priceMax_AB (determines deltaB)", priceMax_AB, 18);
        emit log_named_decimal_uint("priceMax_AC (determines deltaC)", priceMax_AC, 18);

        // Compute all deltas and bounds using ABSOLUTE prices (like Uniswap V3)
        (
            uint256 deltaA,
            uint256 deltaB,
            uint256 deltaC,
            PriceBounds memory bounds_AB,
            PriceBounds memory bounds_AC,
            PriceBounds memory bounds_BC
        ) = computeAllDeltasFrom3Bounds(
            balanceA, balanceB, balanceC,
            ONE, ONE, ONE,  // ← ABSOLUTE prices = 1.0 (Uniswap V3 style)
            priceMin_AB, priceMax_AB, priceMax_AC
        );

        emit log_string("\n--- Computed Deltas ---");
        emit log_named_decimal_uint("deltaA", deltaA, 18);
        emit log_named_decimal_uint("deltaB", deltaB, 18);
        emit log_named_decimal_uint("deltaC", deltaC, 18);

        emit log_string("\n--- Computed Price Bounds for A/B ---");
        emit log_named_decimal_uint("priceMin_AB", bounds_AB.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AB", bounds_AB.priceMax, 18);
        emit log_string("Check priceMin_AB matches input:");
        assertApproxEqRel(bounds_AB.priceMin, priceMin_AB, 0.01e18, "priceMin_AB should match");
        emit log_string("Check priceMax_AB matches input:");
        assertApproxEqRel(bounds_AB.priceMax, priceMax_AB, 0.01e18, "priceMax_AB should match");

        emit log_string("\n--- Computed Price Bounds for A/C ---");
        emit log_named_decimal_uint("priceMin_AC", bounds_AC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC", bounds_AC.priceMax, 18);
        emit log_string("Check priceMax_AC matches input:");
        assertApproxEqRel(bounds_AC.priceMax, priceMax_AC, 0.01e18, "priceMax_AC should match");

        emit log_string("\n--- Computed Price Bounds for B/C ---");
        emit log_named_decimal_uint("priceMin_BC", bounds_BC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_BC", bounds_BC.priceMax, 18);

        emit log_string("\n=== Summary ===");
        emit log_string("SUCCESS: All deltas computed from 3 independent bounds!");
        emit log_string("All other price bounds computed automatically from deltas.");
    }

    /// @notice Swap XYC formula with concentrated liquidity (exactOut)
    function swapXYCConcentrated_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 deltaIn,
        uint256 deltaOut,
        uint256 amountOut
    ) internal pure returns (uint256 amountIn) {
        uint256 concentratedIn = balanceIn + deltaIn;
        uint256 concentratedOut = balanceOut + deltaOut;

        amountIn = Math.ceilDiv(
            amountOut * concentratedIn,
            (concentratedOut - amountOut)
        );
    }

    /// @notice Swap XYC formula with concentrated liquidity (exactIn)
    function swapXYCConcentrated_exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 deltaIn,
        uint256 deltaOut,
        uint256 amountIn
    ) internal pure returns (uint256 amountOut) {
        uint256 concentratedIn = balanceIn + deltaIn;
        uint256 concentratedOut = balanceOut + deltaOut;

        // From: amountOut * concentratedIn = amountIn * (concentratedOut - amountOut)
        // => amountOut * (concentratedIn + amountIn) = amountIn * concentratedOut
        // => amountOut = amountIn * concentratedOut / (concentratedIn + amountIn)

        amountOut = (amountIn * concentratedOut) / (concentratedIn + amountIn);
    }

    /// @notice Test full swaps with rate change verification
    function test_FullSwap_RateChanges() public {
        emit log_string("=== Test: Full Swap with Rate Change Verification ===");

        // Setup: 3 balances and 3 price bounds
        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 150 * ONE;
        uint256 balanceC = 200 * ONE;

        uint256 priceMin_AB = ONE / 4;  // 0.25
        uint256 priceMax_AB = 4 * ONE;
        uint256 priceMax_AC = 6 * ONE;

        emit log_string("\n--- Initial Balances ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Compute deltas using ABSOLUTE prices (like Uniswap V3)
        (
            uint256 deltaA,
            uint256 deltaB,
            uint256 deltaC,
            PriceBounds memory bounds_AB,
            PriceBounds memory bounds_AC,
            PriceBounds memory bounds_BC
        ) = computeAllDeltasFrom3Bounds(
            balanceA, balanceB, balanceC,
            ONE, ONE, ONE,  // ← ABSOLUTE prices = 1.0 (Uniswap V3 style)
            priceMin_AB, priceMax_AB, priceMax_AC
        );

        emit log_string("\n--- Computed Deltas ---");
        emit log_named_decimal_uint("deltaA", deltaA, 18);
        emit log_named_decimal_uint("deltaB", deltaB, 18);
        emit log_named_decimal_uint("deltaC", deltaC, 18);

        emit log_string("\n--- Initial Price Bounds ---");
        emit log_named_decimal_uint("priceMin_AB", bounds_AB.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AB", bounds_AB.priceMax, 18);
        emit log_named_decimal_uint("priceMin_AC", bounds_AC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC", bounds_AC.priceMax, 18);

        // ====== SWAP 1: B -> A (fully drain A) ======
        emit log_string("\n\n=== SWAP 1: B -> A (drain all A) ===");

        // Pre-swap: small test swap for rate
        uint256 preAmountOutA = 0.000001e18;
        uint256 preAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, preAmountOutA
        );

        // Pre-swap: small test swap for rate
        uint256 preAmountOutB = 0.000001e18;
        uint256 preAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, preAmountOutB
        );

        // Full swap: drain all A
        uint256 fullAmountOutA = balanceA;
        uint256 fullAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, fullAmountOutA
        );

        emit log_string("\n--- Swap B->A Amounts ---");
        emit log_named_decimal_uint("amountIn (B)", fullAmountInA, 18);
        emit log_named_decimal_uint("amountOut (A)", fullAmountOutA, 18);

        // Update balances
        balanceB = balanceB + fullAmountInA;
        balanceA = 0;  // Fully drained

        emit log_string("\n--- Balances After B->A ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);

        // Post-swap: small test swap for rate (need to reverse direction)
        uint256 postAmountOutA = 0.000001e18;
        uint256 postAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, postAmountOutA
        );

        // Compute and compare rate change for tokenA
        emit log_string("\n--- Rate Change Analysis for Token A ---");
        uint256 preRateA = preAmountInA * ONE / preAmountOutA;
        uint256 postRateA = postAmountInA * ONE / postAmountOutA;
        uint256 rateChangeA = preRateA * ONE / postRateA;

        emit log_named_decimal_uint("preRateA", preRateA, 18);
        emit log_named_decimal_uint("postRateA", postRateA, 18);
        emit log_named_decimal_uint("rateChangeA", rateChangeA, 18);
        emit log_named_decimal_uint("priceMin_AB (expected)", bounds_AB.priceMin, 18);

        assertApproxEqRel(rateChangeA, bounds_AB.priceMin, 0.02e18, "Quote should be within 2% range of priceMin for tokenA");

        // Check impact on A/C pair (A is also drained in this pair)
        emit log_string("\n--- Impact on A/C Pair ---");
        PriceBounds memory bounds_AC_after = computePriceBounds(balanceA, balanceC, deltaA, deltaC, ONE);
        emit log_named_decimal_uint("priceMin_AC (after)", bounds_AC_after.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC (after)", bounds_AC_after.priceMax, 18);

        // Pre-swap: small test swap for rate
        preAmountOutA = 0.000001e18;
        preAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, preAmountOutA
        );

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");

        // Full swap: drain all B
        uint256 fullAmountOutB = balanceB;
        uint256 fullAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, fullAmountOutB
        );

        emit log_string("\n--- Swap A->B Amounts ---");
        emit log_named_decimal_uint("amountIn (A)", fullAmountInB, 18);
        emit log_named_decimal_uint("amountOut (B)", fullAmountOutB, 18);

        // Update balances
        balanceA = balanceA + fullAmountInB;
        balanceB = 0;  // Fully drained

        emit log_string("\n--- Balances After A->B ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);

        // Post-swap: small test swap for rate (reverse direction)
        uint256 postAmountOutB = 0.000001e18;
        uint256 postAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, postAmountOutB
        );

        // Compute and compare rate change for tokenB
        emit log_string("\n--- Rate Change Analysis for Token B ---");
        uint256 preRateB = preAmountInB * ONE / preAmountOutB;
        uint256 postRateB = postAmountInB * ONE / postAmountOutB;
        uint256 rateChangeB = postRateB * ONE / preRateB;

        emit log_named_decimal_uint("preRateB", preRateB, 18);
        emit log_named_decimal_uint("postRateB", postRateB, 18);
        emit log_named_decimal_uint("rateChangeB", rateChangeB, 18);
        emit log_named_decimal_uint("priceMax_AB (expected)", bounds_AB.priceMax, 18);

        assertApproxEqRel(rateChangeB, bounds_AB.priceMax, 0.02e18, "Quote should be within 2% range of priceMax for tokenB");

        // Pre-swap: small test swap for rate
        uint256 preAmountOutC = 0.000001e18;
        uint256 preAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, preAmountOutC
        );

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");

        // Full swap: drain all C
        uint256 fullAmountOutC = balanceC;
        uint256 fullAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, fullAmountOutC
        );

        emit log_string("\n--- Swap A->C Amounts ---");
        emit log_named_decimal_uint("amountIn (A)", fullAmountInC, 18);
        emit log_named_decimal_uint("amountOut (C)", fullAmountOutC, 18);

        // Update balances
        balanceA = balanceA + fullAmountInC;
        balanceC = 0;  // Fully drained

        emit log_string("\n--- Balances After A->C ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Post-swap: small test swap for rate (reverse direction)
        uint256 postAmountOutC = 0.000001e18;
        uint256 postAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, postAmountOutC
        );

        // Compute and compare rate change for tokenC
        emit log_string("\n--- Rate Change Analysis for Token C ---");
        uint256 preRateC = preAmountInC * ONE / preAmountOutC;
        uint256 postRateC = postAmountInC * ONE / postAmountOutC;
        uint256 rateChangeC = postRateC * ONE / preRateC;

        emit log_named_decimal_uint("preRateC", preRateC, 18);
        emit log_named_decimal_uint("postRateC", postRateC, 18);
        emit log_named_decimal_uint("rateChangeC", rateChangeC, 18);
        emit log_named_decimal_uint("priceMax_AC (expected)", bounds_AC.priceMax, 18);

        assertApproxEqRel(rateChangeC, bounds_AC.priceMax, 0.02e18, "Quote should be within 2% range of priceMax for tokenC");

        // ====== SWAP 4: С -> A (fully drain A) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A) ===");

        // Full swap: drain all A
        fullAmountOutA = balanceA;
        fullAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, fullAmountOutA
        );

        emit log_string("\n--- Swap A->C Amounts ---");
        emit log_named_decimal_uint("amountIn (A)", fullAmountInA, 18);
        emit log_named_decimal_uint("amountOut (C)", fullAmountOutA, 18);

        // Update balances
        balanceA = 0;  // Fully drained
        balanceC = balanceC + fullAmountInA;

        emit log_string("\n--- Balances After A->C ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Post-swap: small test swap for rate (reverse direction)
        postAmountOutA = 0.000001e18;
        postAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, postAmountOutA
        );

        // Compute and compare rate change for tokenA
        emit log_string("\n--- Rate Change Analysis for Token A ---");
        preRateA = preAmountInA * ONE / preAmountOutA;
        postRateA = postAmountInA * ONE / postAmountOutA;
        rateChangeA = preRateA * ONE / postRateA;

        emit log_named_decimal_uint("preRateA", preRateA, 18);
        emit log_named_decimal_uint("postRateA", postRateA, 18);
        emit log_named_decimal_uint("rateChangeA", rateChangeA, 18);
        emit log_named_decimal_uint("priceMin_AC (expected)", bounds_AC.priceMin, 18);

        assertApproxEqRel(rateChangeA, bounds_AC.priceMin, 0.02e18, "Quote should be within 2% range of priceMin for tokenA");

        emit log_string("\n\n=== Test Complete: All rate changes verified! ===");
    }

    /// @notice Test full swaps with CURRENT prices (not absolute 1.0)
    function test_FullSwap_RateChanges_CurrentPrice() public {
        emit log_string("=== Test: Full Swap with Current Prices (Relative Bounds) ===");

        // Setup: 3 balances (different values to have different prices)
        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 150 * ONE;
        uint256 balanceC = 200 * ONE;

        // Calculate current prices
        uint256 price_AB = balanceB * ONE / balanceA;  // 1.5
        uint256 price_AC = balanceC * ONE / balanceA;  // 2.0
        uint256 price_BC = balanceC * ONE / balanceB;  // 1.333...

        // Define relative ranges (±4x for A/B, ±6x for A/C)
        uint256 priceMin_AB = price_AB / 4;  // 1.5 / 4 = 0.375
        uint256 priceMax_AB = price_AB * 4;  // 1.5 * 4 = 6.0
        uint256 priceMax_AC = price_AC * 6;  // 2.0 * 6 = 12.0

        emit log_string("\n--- Initial Balances ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        emit log_string("\n--- Current Prices ---");
        emit log_named_decimal_uint("price_AB", price_AB, 18);
        emit log_named_decimal_uint("price_AC", price_AC, 18);
        emit log_named_decimal_uint("price_BC", price_BC, 18);

        emit log_string("\n--- Price Bounds (relative to current) ---");
        emit log_named_decimal_uint("priceMin_AB", priceMin_AB, 18);
        emit log_named_decimal_uint("priceMax_AB", priceMax_AB, 18);
        emit log_named_decimal_uint("priceMax_AC", priceMax_AC, 18);

        // Compute deltas using CURRENT prices
        (
            uint256 deltaA,
            uint256 deltaB,
            uint256 deltaC,
            PriceBounds memory bounds_AB,
            PriceBounds memory bounds_AC,
            PriceBounds memory bounds_BC
        ) = computeAllDeltasFrom3Bounds(
            balanceA, balanceB, balanceC,
            price_AB, price_AC, price_BC,  // ← CURRENT prices!
            priceMin_AB, priceMax_AB, priceMax_AC
        );

        emit log_string("\n--- Computed Deltas ---");
        emit log_named_decimal_uint("deltaA", deltaA, 18);
        emit log_named_decimal_uint("deltaB", deltaB, 18);
        emit log_named_decimal_uint("deltaC", deltaC, 18);

        emit log_string("\n--- Computed Price Bounds ---");
        emit log_named_decimal_uint("priceMin_AB", bounds_AB.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AB", bounds_AB.priceMax, 18);
        emit log_named_decimal_uint("priceMin_AC", bounds_AC.priceMin, 18);
        emit log_named_decimal_uint("priceMax_AC", bounds_AC.priceMax, 18);

        // ====== SWAP 1: B -> A (fully drain A) ======
        emit log_string("\n\n=== SWAP 1: B -> A (drain all A) ===");

        // Pre-swap: small test swaps for rates
        uint256 preAmountOutA = 0.000001e18;
        uint256 preAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, preAmountOutA
        );

        uint256 preAmountOutB = 0.000001e18;
        uint256 preAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, preAmountOutB
        );

        // Full swap: drain all A
        uint256 fullAmountOutA = balanceA;
        uint256 fullAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, fullAmountOutA
        );

        emit log_string("\n--- Swap B->A Amounts ---");
        emit log_named_decimal_uint("amountIn (B)", fullAmountInA, 18);
        emit log_named_decimal_uint("amountOut (A)", fullAmountOutA, 18);

        // Update balances
        balanceB = balanceB + fullAmountInA;
        balanceA = 0;

        emit log_string("\n--- Balances After B->A ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);

        // Post-swap rate
        uint256 postAmountOutA = 0.000001e18;
        uint256 postAmountInA = swapXYCConcentrated_exactOut(
            balanceB, balanceA, deltaB, deltaA, postAmountOutA
        );

        emit log_string("\n--- Rate Change Analysis for Token A ---");
        uint256 preRateA = preAmountInA * ONE / preAmountOutA;
        uint256 postRateA = postAmountInA * ONE / postAmountOutA;
        uint256 rateChangeA = preRateA * ONE / postRateA;

        emit log_named_decimal_uint("preRateA", preRateA, 18);
        emit log_named_decimal_uint("postRateA", postRateA, 18);
        emit log_named_decimal_uint("rateChangeA", rateChangeA, 18);
        emit log_named_decimal_uint("priceMin_AB (expected)", bounds_AB.priceMin * ONE / price_AB, 18);

        assertApproxEqRel(rateChangeA, bounds_AB.priceMin * ONE / price_AB, 0.02e18, "Rate change should match priceMin_AB");

        // Save pre-rate for A/C pair (after A drained)
        preAmountOutA = 0.000001e18;
        preAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, preAmountOutA
        );

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");

        uint256 fullAmountOutB = balanceB;
        uint256 fullAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, fullAmountOutB
        );

        emit log_string("\n--- Swap A->B Amounts ---");
        emit log_named_decimal_uint("amountIn (A)", fullAmountInB, 18);
        emit log_named_decimal_uint("amountOut (B)", fullAmountOutB, 18);

        balanceA = balanceA + fullAmountInB;
        balanceB = 0;

        emit log_string("\n--- Balances After A->B ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);

        uint256 postAmountOutB = 0.000001e18;
        uint256 postAmountInB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, postAmountOutB
        );

        emit log_string("\n--- Rate Change Analysis for Token B ---");
        uint256 preRateB = preAmountInB * ONE / preAmountOutB;
        uint256 postRateB = postAmountInB * ONE / postAmountOutB;
        uint256 rateChangeB = postRateB * ONE / preRateB;

        emit log_named_decimal_uint("preRateB", preRateB, 18);
        emit log_named_decimal_uint("postRateB", postRateB, 18);
        emit log_named_decimal_uint("rateChangeB", rateChangeB, 18);
        emit log_named_decimal_uint("priceMax_AB (expected)", bounds_AB.priceMax * ONE / price_AB, 18);

        assertApproxEqRel(rateChangeB, bounds_AB.priceMax * ONE / price_AB, 0.02e18, "Rate change should match priceMax_AB");

        // Save pre-rate for C
        uint256 preAmountOutC = 0.000001e18;
        uint256 preAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, preAmountOutC
        );

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");

        uint256 fullAmountOutC = balanceC;
        uint256 fullAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, fullAmountOutC
        );

        emit log_string("\n--- Swap A->C Amounts ---");
        emit log_named_decimal_uint("amountIn (A)", fullAmountInC, 18);
        emit log_named_decimal_uint("amountOut (C)", fullAmountOutC, 18);

        balanceA = balanceA + fullAmountInC;
        balanceC = 0;

        emit log_string("\n--- Balances After A->C ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        uint256 postAmountOutC = 0.000001e18;
        uint256 postAmountInC = swapXYCConcentrated_exactOut(
            balanceA, balanceC, deltaA, deltaC, postAmountOutC
        );

        emit log_string("\n--- Rate Change Analysis for Token C ---");
        uint256 preRateC = preAmountInC * ONE / preAmountOutC;
        uint256 postRateC = postAmountInC * ONE / postAmountOutC;
        uint256 rateChangeC = postRateC * ONE / preRateC;

        emit log_named_decimal_uint("preRateC", preRateC, 18);
        emit log_named_decimal_uint("postRateC", postRateC, 18);
        emit log_named_decimal_uint("rateChangeC", rateChangeC, 18);
        emit log_named_decimal_uint("priceMax_AC (expected)", bounds_AC.priceMax * ONE / price_AC, 18);

        assertApproxEqRel(rateChangeC, bounds_AC.priceMax * ONE / price_AC, 0.02e18, "Rate change should match priceMax_AC");

        // ====== SWAP 4: C -> A (fully drain A again) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A) ===");

        fullAmountOutA = balanceA;
        fullAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, fullAmountOutA
        );

        emit log_string("\n--- Swap C->A Amounts ---");
        emit log_named_decimal_uint("amountIn (C)", fullAmountInA, 18);
        emit log_named_decimal_uint("amountOut (A)", fullAmountOutA, 18);

        balanceA = 0;
        balanceC = balanceC + fullAmountInA;

        emit log_string("\n--- Balances After C->A ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        postAmountOutA = 0.000001e18;
        postAmountInA = swapXYCConcentrated_exactOut(
            balanceC, balanceA, deltaC, deltaA, postAmountOutA
        );

        emit log_string("\n--- Rate Change Analysis for Token A (via C) ---");
        preRateA = preAmountInA * ONE / preAmountOutA;
        postRateA = postAmountInA * ONE / postAmountOutA;
        rateChangeA = preRateA * ONE / postRateA;

        emit log_named_decimal_uint("preRateA", preRateA, 18);
        emit log_named_decimal_uint("postRateA", postRateA, 18);
        emit log_named_decimal_uint("rateChangeA", rateChangeA, 18);
        emit log_named_decimal_uint("priceMin_AC (expected)", bounds_AC.priceMin * ONE / price_AC, 18);

        assertApproxEqRel(rateChangeA, bounds_AC.priceMin * ONE / price_AC, 0.02e18, "Rate change should match priceMin_AC");

        emit log_string("\n\n=== Test Complete: Current Price approach verified! ===");
    }

    /// @notice Test partial swaps and check for arbitrage opportunities
    function test_PartialSwaps_ArbitrageCheck() public {
        emit log_string("=== Test: Partial Swaps & Arbitrage Detection ===");

        // Setup: 3 balances
        uint256 balanceA = 100 * ONE;
        uint256 balanceB = 150 * ONE;
        uint256 balanceC = 300 * ONE;

        uint256 priceMin_AB = ONE / 4;
        uint256 priceMax_AB = 4 * ONE;
        uint256 priceMax_AC = 6 * ONE;

        emit log_string("\n--- Initial State ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Compute deltas
        (
            uint256 deltaA,
            uint256 deltaB,
            uint256 deltaC,
            ,
            ,
        ) = computeAllDeltasFrom3Bounds(
            balanceA, balanceB, balanceC,
            ONE, ONE, ONE,
            priceMin_AB, priceMax_AB, priceMax_AC
        );

        emit log_string("\n--- Deltas ---");
        emit log_named_decimal_uint("deltaA", deltaA, 18);
        emit log_named_decimal_uint("deltaB", deltaB, 18);
        emit log_named_decimal_uint("deltaC", deltaC, 18);

        // Calculate initial prices
        uint256 initialPrice_AB = getPrice(balanceA, balanceB, deltaA, deltaB);
        uint256 initialPrice_AC = getPrice(balanceA, balanceC, deltaA, deltaC);
        uint256 initialPrice_BC = getPrice(balanceB, balanceC, deltaB, deltaC);

        emit log_string("\n--- Initial Prices (small swap quotes) ---");
        emit log_named_decimal_uint("price_AB", initialPrice_AB, 18);
        emit log_named_decimal_uint("price_AC", initialPrice_AC, 18);
        emit log_named_decimal_uint("price_BC", initialPrice_BC, 18);

        // Check initial arbitrage (should be none)
        emit log_string("\n--- Initial Arbitrage Check ---");
        checkArbitrage(balanceA, balanceB, balanceC, deltaA, deltaB, deltaC, "Initial");

        // ====== PARTIAL SWAP 1: Swap 50% of A for B ======
        emit log_string("\n\n=== SWAP 1: Swap 50% of A for B ===");

        uint256 swapAmountA = balanceA / 2;  // 50%
        uint256 receivedB = swapXYCConcentrated_exactOut(
            balanceA, balanceB, deltaA, deltaB, swapAmountA
        );

        emit log_named_decimal_uint("Swapped A", swapAmountA, 18);
        emit log_named_decimal_uint("Received B", receivedB, 18);

        // Update balances
        balanceA = balanceA - swapAmountA;
        balanceB = balanceB + receivedB;

        emit log_string("\n--- Balances After SWAP 1 ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        // Calculate new prices
        uint256 price_AB_after = getPrice(balanceA, balanceB, deltaA, deltaB);
        uint256 price_AC_after = getPrice(balanceA, balanceC, deltaA, deltaC);
        uint256 price_BC_after = getPrice(balanceB, balanceC, deltaB, deltaC);

        emit log_string("\n--- Prices After SWAP 1 ---");
        emit log_named_decimal_uint("price_AB", price_AB_after, 18);
        emit log_named_decimal_uint("price_AC", price_AC_after, 18);
        emit log_named_decimal_uint("price_BC", price_BC_after, 18);

        // Check for arbitrage opportunity
        emit log_string("\n--- Arbitrage Check After SWAP 1 ---");
        checkArbitrage(balanceA, balanceB, balanceC, deltaA, deltaB, deltaC, "After SWAP 1");

        // ====== PARTIAL SWAP 2: Swap 50% of B for C ======
        emit log_string("\n\n=== SWAP 2: Swap 50% of B for C ===");

        uint256 swapAmountB = balanceB / 2;
        uint256 receivedC = swapXYCConcentrated_exactOut(
            balanceB, balanceC, deltaB, deltaC, swapAmountB
        );

        emit log_named_decimal_uint("Swapped B", swapAmountB, 18);
        emit log_named_decimal_uint("Received C", receivedC, 18);

        balanceB = balanceB - swapAmountB;
        balanceC = balanceC + receivedC;

        emit log_string("\n--- Balances After SWAP 2 ---");
        emit log_named_decimal_uint("balanceA", balanceA, 18);
        emit log_named_decimal_uint("balanceB", balanceB, 18);
        emit log_named_decimal_uint("balanceC", balanceC, 18);

        price_AB_after = getPrice(balanceA, balanceB, deltaA, deltaB);
        price_AC_after = getPrice(balanceA, balanceC, deltaA, deltaC);
        price_BC_after = getPrice(balanceB, balanceC, deltaB, deltaC);

        emit log_string("\n--- Prices After SWAP 2 ---");
        emit log_named_decimal_uint("price_AB", price_AB_after, 18);
        emit log_named_decimal_uint("price_AC", price_AC_after, 18);
        emit log_named_decimal_uint("price_BC", price_BC_after, 18);

        emit log_string("\n--- Arbitrage Check After SWAP 2 ---");
        checkArbitrage(balanceA, balanceB, balanceC, deltaA, deltaB, deltaC, "After SWAP 2");

        emit log_string("\n\n=== Test Complete ===");
    }

    /// @notice Get current price for a pair (using small swap)
    function getPrice(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 deltaIn,
        uint256 deltaOut
    ) internal pure returns (uint256 price) {
        uint256 testAmount = 1 * ONE;
        uint256 received = swapXYCConcentrated_exactOut(
            balanceIn, balanceOut, deltaIn, deltaOut, testAmount
        );
        price = received * ONE / testAmount;
    }

    /// @notice Check for arbitrage opportunities across all cycles
    function checkArbitrage(
        uint256 balanceA,
        uint256 balanceB,
        uint256 balanceC,
        uint256 deltaA,
        uint256 deltaB,
        uint256 deltaC,
        string memory label
    ) internal {
        emit log_string(string(abi.encodePacked("\n--- Arbitrage Analysis: ", label, " ---")));

        // ===== CYCLE 1: A -> B -> C -> A =====
        uint256 startA = balanceA / 2;  // Start with 50% of A for the cycle

        // Create copies of balances for this cycle
        uint256 bal_A = balanceA;
        uint256 bal_B = balanceB;
        uint256 bal_C = balanceC;

        // Swap 1: A -> B
        uint256 afterB = swapXYCConcentrated_exactIn(bal_A, bal_B, deltaA, deltaB, startA);
        bal_A += startA;   // Pool receives A
        bal_B -= afterB;   // Pool sends B

        // Swap 2: B -> C
        uint256 afterC = swapXYCConcentrated_exactIn(bal_B, bal_C, deltaB, deltaC, afterB);
        bal_B += afterB;   // Pool receives B
        bal_C -= afterC;   // Pool sends C

        // Swap 3: C -> A
        uint256 finalA = swapXYCConcentrated_exactIn(bal_C, bal_A, deltaC, deltaA, afterC);
        bal_C += afterC;   // Pool receives C
        bal_A -= finalA;   // Pool sends A

        emit log_string("\nCycle A->B->C->A:");
        emit log_named_decimal_uint("  Start with A", startA, 18);
        emit log_named_decimal_uint("  After A->B (received B)", afterB, 18);
        emit log_named_decimal_uint("  After B->C (received C)", afterC, 18);
        emit log_named_decimal_uint("  Final A", finalA, 18);

        if (finalA > startA) {
            uint256 profit = finalA - startA;
            uint256 profitPct = (profit * 10000) / startA;
            emit log_named_uint("  ARBITRAGE PROFIT (bps)", profitPct);
            emit log_named_string("  Result", "Profitable cycle found!");
        } else {
            uint256 loss = startA - finalA;
            uint256 lossPct = (loss * 10000) / startA;
            emit log_named_uint("  Loss (bps)", lossPct);
            emit log_named_string("  Result", "No arbitrage");
        }

        // ===== CYCLE 2: A -> C -> B -> A (with INITIAL balances!) =====
        uint256 startA2 = balanceA / 2;  // Start with 50% of A for the cycle

        // Reset balances to initial state
        bal_A = balanceA;
        bal_B = balanceB;
        bal_C = balanceC;

        // Swap 1: A -> C
        uint256 afterC2 = swapXYCConcentrated_exactIn(bal_A, bal_C, deltaA, deltaC, startA2);
        bal_A += startA2;   // Pool receives A
        bal_C -= afterC2;   // Pool sends C

        // Swap 2: C -> B
        uint256 afterB2 = swapXYCConcentrated_exactIn(bal_C, bal_B, deltaC, deltaB, afterC2);
        bal_C += afterC2;   // Pool receives C
        bal_B -= afterB2;   // Pool sends B

        // Swap 3: B -> A
        uint256 finalA2 = swapXYCConcentrated_exactIn(bal_B, bal_A, deltaB, deltaA, afterB2);
        bal_B += afterB2;   // Pool receives B
        bal_A -= finalA2;   // Pool sends A

        emit log_string("\nCycle A->C->B->A:");
        emit log_named_decimal_uint("  Start with A", startA2, 18);
        emit log_named_decimal_uint("  After A->C (received C)", afterC2, 18);
        emit log_named_decimal_uint("  After C->B (received B)", afterB2, 18);
        emit log_named_decimal_uint("  Final A", finalA2, 18);

        if (finalA2 > startA2) {
            uint256 profit = finalA2 - startA2;
            uint256 profitPct = (profit * 10000) / startA2;
            emit log_named_uint("  ARBITRAGE PROFIT (bps)", profitPct);
            emit log_named_string("  Result", "Profitable cycle found!");
        } else {
            uint256 loss = startA2 - finalA2;
            uint256 lossPct = (loss * 10000) / startA2;
            emit log_named_uint("  Loss (bps)", lossPct);
            emit log_named_string("  Result", "No arbitrage");
        }
    }

    /// @notice Test Impermanent Loss in concentrated liquidity
    function test_ImpermanentLoss_PriceChange() public {
        emit log_string("=== Test: Impermanent Loss Analysis ===");

        // Initial setup
        uint256 initialBalanceA = 100 * ONE;
        uint256 initialBalanceB = 100 * ONE;
        uint256 initialBalanceC = 100 * ONE;

        // Set equal deltas for symmetric concentration
        uint256 deltaA = 100 * ONE;
        uint256 deltaB = 100 * ONE;
        uint256 deltaC = 100 * ONE;

        emit log_string("\n--- Initial State ---");
        emit log_named_decimal_uint("Initial A", initialBalanceA, 18);
        emit log_named_decimal_uint("Initial B", initialBalanceB, 18);
        emit log_named_decimal_uint("Initial C", initialBalanceC, 18);
        emit log_named_decimal_uint("Delta (all)", deltaA, 18);

        // Calculate initial portfolio value (in terms of A)
        uint256 initialValue = initialBalanceA + initialBalanceB + initialBalanceC;
        emit log_string("\n--- Initial Portfolio Value (in A units) ---");
        emit log_named_decimal_uint("Total Value", initialValue, 18);

        // ===== SCENARIO 1: Token B doubles in price =====
        emit log_string("\n\n=== SCENARIO 1: Token B price doubles (B/A = 2.0) ===");

        // Simulate external price change: B doubles relative to A
        // Arbitrageurs will swap A for B until pool price matches external price

        // Calculate how much A needs to be swapped to reach price = 2.0
        // At price 2.0: balanceB_new / balanceA_new ≈ 2.0
        // We need to drain A to increase its price

        uint256 balanceA = initialBalanceA;
        uint256 balanceB = initialBalanceB;
        uint256 balanceC = initialBalanceC;

        // Arbitrage: Swap A for B until price ≈ 2.0
        // Target: balanceB / balanceA = 2.0
        // concentrated: (balanceB + deltaB) / (balanceA + deltaA) ≈ 2.0
        // 200 / 200 = 1.0 initially
        // Need: (balanceB_new + 100) / (balanceA_new + 100) ≈ 2.0

        // Drain some A to increase price
        uint256 targetPrice = 2 * ONE;
        uint256 amountToDrain = 50 * ONE; // Drain 50% of A

        uint256 amountReceived = swapXYCConcentrated_exactIn(
            balanceA, balanceB, deltaA, deltaB, amountToDrain
        );

        balanceA += amountToDrain;
        balanceB -= amountReceived;

        emit log_string("\n--- After Arbitrage to Price 2.0 ---");
        emit log_named_decimal_uint("Pool Balance A", balanceA, 18);
        emit log_named_decimal_uint("Pool Balance B", balanceB, 18);
        emit log_named_decimal_uint("A swapped in", amountToDrain, 18);
        emit log_named_decimal_uint("B received out", amountReceived, 18);

        // Current pool price
        uint256 currentPrice_AB = getPrice(balanceA, balanceB, deltaA, deltaB);
        emit log_named_decimal_uint("Current price B/A", currentPrice_AB, 18);

        // ===== Calculate Impermanent Loss =====
        emit log_string("\n--- Impermanent Loss Calculation ---");

        // HODL Strategy Value (if just held tokens at new prices)
        // Price of B doubled (B/A = 2.0), C stays same (C/A = 1.0)
        uint256 holdValueA = initialBalanceA; // 100 A
        uint256 holdValueB = initialBalanceB * 2; // 100 B * 2 = 200 A-equivalent
        uint256 holdValueC = initialBalanceC; // 100 C = 100 A-equivalent
        uint256 totalHoldValue = holdValueA + holdValueB + holdValueC;

        emit log_named_decimal_uint("HODL Value (A)", holdValueA, 18);
        emit log_named_decimal_uint("HODL Value (B in A)", holdValueB, 18);
        emit log_named_decimal_uint("HODL Value (C in A)", holdValueC, 18);
        emit log_named_decimal_uint("Total HODL Value", totalHoldValue, 18);

        // LP Strategy Value (withdraw from pool at new prices)
        // Our LP position: still owns the pool
        // Pool now has: balanceA, balanceB, balanceC
        uint256 lpValueA = balanceA;
        uint256 lpValueB = balanceB * 2; // Convert to A at new price
        uint256 lpValueC = balanceC; // C unchanged
        uint256 totalLpValue = lpValueA + lpValueB + lpValueC;

        emit log_named_decimal_uint("LP Value (A)", lpValueA, 18);
        emit log_named_decimal_uint("LP Value (B in A)", lpValueB, 18);
        emit log_named_decimal_uint("LP Value (C in A)", lpValueC, 18);
        emit log_named_decimal_uint("Total LP Value", totalLpValue, 18);

        // Impermanent Loss
        int256 il = int256(totalLpValue) - int256(totalHoldValue);
        uint256 ilPercentage = il < 0
            ? uint256(-il) * 10000 / totalHoldValue
            : uint256(il) * 10000 / totalHoldValue;

        emit log_string("\n--- Result ---");
        if (il < 0) {
            emit log_named_uint("Impermanent Loss (bps)", ilPercentage);
            emit log_named_string("Status", "LP LOST value vs HODL");
        } else {
            emit log_named_uint("Impermanent Gain (bps)", ilPercentage);
            emit log_named_string("Status", "LP GAINED value vs HODL");
        }

        // ===== SCENARIO 2: All prices change =====
        emit log_string("\n\n=== SCENARIO 2: Complex price change (B=2x, C=1.5x) ===");

        // Reset to initial
        balanceA = initialBalanceA;
        balanceB = initialBalanceB;
        balanceC = initialBalanceC;

        // Simulate B doubles, C increases 1.5x
        // Arbitrage B first
        amountToDrain = 50 * ONE;
        amountReceived = swapXYCConcentrated_exactIn(
            balanceA, balanceB, deltaA, deltaB, amountToDrain
        );
        balanceA += amountToDrain;
        balanceB -= amountReceived;

        // Arbitrage C
        uint256 amountAforC = 25 * ONE;
        uint256 amountCReceived = swapXYCConcentrated_exactIn(
            balanceA, balanceC, deltaA, deltaC, amountAforC
        );
        balanceA += amountAforC;
        balanceC -= amountCReceived;

        emit log_string("\n--- After Complex Arbitrage ---");
        emit log_named_decimal_uint("Pool Balance A", balanceA, 18);
        emit log_named_decimal_uint("Pool Balance B", balanceB, 18);
        emit log_named_decimal_uint("Pool Balance C", balanceC, 18);

        // HODL value
        holdValueA = initialBalanceA;
        holdValueB = initialBalanceB * 2; // B = 2x
        holdValueC = (initialBalanceC * 3) / 2; // C = 1.5x
        totalHoldValue = holdValueA + holdValueB + holdValueC;

        // LP value
        lpValueA = balanceA;
        lpValueB = balanceB * 2;
        lpValueC = (balanceC * 3) / 2;
        totalLpValue = lpValueA + lpValueB + lpValueC;

        emit log_string("\n--- Impermanent Loss (Complex) ---");
        emit log_named_decimal_uint("HODL Value", totalHoldValue, 18);
        emit log_named_decimal_uint("LP Value", totalLpValue, 18);

        il = int256(totalLpValue) - int256(totalHoldValue);
        ilPercentage = il < 0
            ? uint256(-il) * 10000 / totalHoldValue
            : uint256(il) * 10000 / totalHoldValue;

        if (il < 0) {
            emit log_named_uint("Impermanent Loss (bps)", ilPercentage);
        } else {
            emit log_named_uint("Impermanent Gain (bps)", ilPercentage);
        }

        emit log_string("\n\n=== Test Complete ===");
    }
}
