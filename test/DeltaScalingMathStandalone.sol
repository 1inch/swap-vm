// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Pure mathematical test of delta scaling in multi-token pools
/// @notice Tests concentration preservation through delta updates without SwapVM
contract DeltaScalingMathTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant SQRT_ONE = 1e9;

    struct PairState {
        uint256 balanceA;
        uint256 balanceB;
        uint256 deltaA;
        uint256 deltaB;
        uint256 liquidity;
    }

    /// @notice Compute deltaA (lower bound) using concentration formula
    /// @dev deltaA = balanceA / (sqrt(price / priceMin) - 1)
    function computeDeltaA(
        uint256 balanceA,
        uint256 price,
        uint256 priceMin
    ) internal pure returns (uint256) {
        if (price == priceMin) return 0;
        uint256 sqrtRatio = Math.sqrt(price * ONE / priceMin) * SQRT_ONE;
        require(sqrtRatio > ONE, "Invalid price ratio for deltaA");
        return balanceA * ONE / (sqrtRatio - ONE);
        // deltaA = balanceA0 / (sqrt(price / priceMin) - 1)
        // price = C/A, priceMin = priceMin => deltaA = balanceA0 / (sqrt((balanceC0/balanceA0) / priceMin) - 1)
        // deltaA_new = (balanceA0+amount) / (sqrt((balanceC0/(balanceA0+amount)) / priceMin) - 1)
        // price / priceMin = K
        // deltaA = balanceA0 / (sqrt(K) - 1)
        // K = (balanceA0 / deltaA + 1) ^ 2 = ((balanceA0 + deltaA) / deltaA) ^ 2
        // deltaA_new = (balanceA0+amount) / (sqrt(K * balanceA0 / (balanceA0+amount)) - 1)
    }

    /// @notice Compute deltaB (upper bound) using concentration formula
    /// @dev deltaB = balanceB / (sqrt(priceMax / price) - 1)
    function computeDeltaB(
        uint256 balanceB,
        uint256 price,
        uint256 priceMax
    ) internal pure returns (uint256) {
        if (price == priceMax) return 0;
        uint256 sqrtRatio = Math.sqrt(priceMax * ONE / price) * SQRT_ONE;
        require(sqrtRatio > ONE, "Invalid price ratio for deltaB");
        return balanceB * ONE / (sqrtRatio - ONE);
        // deltaB = balanceB0 / (sqrt(priceMax / price) - 1)
        // price = B/A, priceMax = priceMax => deltaB = balanceB0 / (sqrt(priceMax/(balanceB0/balanceA0)) - 1)
        // deltaB_new = (balanceB0+-amount) / (sqrt(priceMax / ((balanceB0+-amount)/balanceA0)) - 1)
        // price / priceMin = K
        // deltaB = balanceB0 / (sqrt(K) - 1)
        // K = (balanceB0 / deltaB + 1) ^ 2 = ((balanceB0 + deltaB) / deltaB) ^ 2
        // deltaB_new = (balanceB0+-amount) / (sqrt(K * balanceB0 / (balanceB0+amount)) - 1)
    }

    /// @notice Update BOTH deltas when balances change in adjacent pair
    /// @dev For pair (A, C): when A changes, both deltaA and deltaC must update
    ///      deltaA depends on price/priceMin where price = C/A
    ///      deltaC depends on priceMax/price where price = C/A
    function updateDeltas(
        uint256 balanceA_old,
        uint256 balanceA_new,
        uint256 balanceC_old,
        uint256 balanceC_new,
        uint256 deltaA_old,
        uint256 deltaC_old
    ) internal pure returns (uint256 deltaA_new, uint256 deltaC_new) {
        if (balanceA_old == 0 || deltaA_old == 0) return (0, deltaC_old);
        if (balanceC_old == 0 || deltaC_old == 0) return (deltaA_old, 0);

        // K_A depends on sqrt((C/A) / priceMin) = sqrt(C / (A * priceMin))
        // When A increases or C decreases: K_A decreases
        uint256 K_A0_scaled = balanceA_old * ONE / deltaA_old + ONE;
        uint256 K_A1_scaled = K_A0_scaled * Math.sqrt(balanceA_old * ONE / balanceA_new) / SQRT_ONE * Math.sqrt(balanceC_new * ONE / balanceC_old) / SQRT_ONE;

        // K_C depends on sqrt(priceMax / (C/A)) = sqrt(priceMax * A / C)
        // When A increases or C decreases: K_C increases
        uint256 K_C0_scaled = balanceC_old * ONE / deltaC_old + ONE;
        uint256 K_C1_scaled = K_C0_scaled * Math.sqrt(balanceA_new * ONE / balanceA_old) / SQRT_ONE * Math.sqrt(balanceC_old * ONE / balanceC_new) / SQRT_ONE;

        deltaA_new = balanceA_new * ONE / (K_A1_scaled - ONE);
        deltaC_new = balanceC_new * ONE / (K_C1_scaled - ONE);
    }

    /// @notice XYC exactOut formula: amountIn = L^2 / (concentratedOut - amountOut) - concentratedIn
    /// @param concentratedIn Concentrated balance in (physical + delta)
    /// @param concentratedOut Concentrated balance out (physical + delta)
    /// @param amountOut Desired output amount
    function swapXYC_exactOut(
        uint256 concentratedIn,
        uint256 concentratedOut,
        uint256 amountOut
    ) internal pure returns (uint256 amountIn) {
        amountIn = Math.ceilDiv( // Ceiling division for tokenIn is desired behavior
            amountOut * concentratedIn,
            (concentratedOut - amountOut)
        );
    }

    function test_ThreeTokenConcentrationPreservation() public {
        // Initial setup: 3 tokens A, B, C with equal balances
        uint256 initialBalance = 100 * ONE;
        uint256 price = ONE; // All prices 1:1 initially
        uint256 priceMin = ONE / 2; // 0.5
        uint256 priceMax = 2 * ONE; // 2.0

        // Initialize all pairs
        PairState memory pairAB;
        PairState memory pairAC;
        PairState memory pairBC;

        // Pair A/B
        pairAB.balanceA = initialBalance;
        pairAB.balanceB = initialBalance;
        pairAB.deltaA = computeDeltaA(pairAB.balanceA, price, priceMin);
        pairAB.deltaB = computeDeltaB(pairAB.balanceB, price, priceMax);
        pairAB.liquidity = Math.sqrt((pairAB.balanceA + pairAB.deltaA) * (pairAB.balanceB + pairAB.deltaB));

        // Pair A/C
        pairAC.balanceA = initialBalance;
        pairAC.balanceB = initialBalance; // B is C here
        pairAC.deltaA = computeDeltaA(pairAC.balanceA, price, priceMin);
        pairAC.deltaB = computeDeltaB(pairAC.balanceB, price, priceMax);
        pairAC.liquidity = Math.sqrt((pairAC.balanceA + pairAC.deltaA) * (pairAC.balanceB + pairAC.deltaB));

        // Pair B/C
        pairBC.balanceA = initialBalance; // A is B here
        pairBC.balanceB = initialBalance; // B is C here
        pairBC.deltaA = computeDeltaA(pairBC.balanceA, price, priceMin);
        pairBC.deltaB = computeDeltaB(pairBC.balanceB, price, priceMax);
        pairBC.liquidity = Math.sqrt((pairBC.balanceA + pairBC.deltaA) * (pairBC.balanceB + pairBC.deltaB));

        emit log_named_decimal_uint("Initial balance A", pairAB.balanceA, 18);
        emit log_named_decimal_uint("Initial delta A (AB)", pairAB.deltaA, 18);
        emit log_named_decimal_uint("Initial delta A (AC)", pairAC.deltaA, 18);

        // Step 1: Swap A→B (10 tokens out)
        uint256 amountOut = 10 * ONE;
        uint256 concentratedA = pairAB.balanceA + pairAB.deltaA;
        uint256 concentratedB = pairAB.balanceB + pairAB.deltaB;
        uint256 amountIn = swapXYC_exactOut(concentratedA, concentratedB, amountOut);

        pairAB.balanceA += amountIn;
        pairAB.balanceB -= amountOut;

        // Update liquidity after swap
        concentratedA = pairAB.balanceA + pairAB.deltaA;
        concentratedB = pairAB.balanceB + pairAB.deltaB;
        pairAB.liquidity = Math.sqrt(concentratedA * concentratedB);

        emit log_string("\n=== After A->B swap ===");
        emit log_named_decimal_uint("Balance A", pairAB.balanceA, 18);
        emit log_named_decimal_uint("Balance B", pairAB.balanceB, 18);

        // Update deltas for affected pairs (A/C and B/C)
        // A increased in A/B swap, so update BOTH deltas in pair A/C
        uint256 oldDeltaA_AC = pairAC.deltaA;
        uint256 oldDeltaC_AC = pairAC.deltaB;
        (pairAC.deltaA, pairAC.deltaB) = updateDeltas(
            pairAC.balanceA, pairAB.balanceA,  // A: old -> new
            pairAC.balanceB, pairAC.balanceB,  // C: unchanged
            pairAC.deltaA, pairAC.deltaB
        );
        pairAC.balanceA = pairAB.balanceA;

        emit log_named_decimal_uint("Updated delta A (AC)", pairAC.deltaA, 18);
        emit log_named_decimal_uint("Updated delta C (AC)", pairAC.deltaB, 18);
        emit log_named_decimal_uint("Delta A change", pairAC.deltaA > oldDeltaA_AC ? pairAC.deltaA - oldDeltaA_AC : 0, 18);
        emit log_named_decimal_uint("Delta C change", pairAC.deltaB > oldDeltaC_AC ? pairAC.deltaB - oldDeltaC_AC : 0, 18);

        // B decreased in A/B swap, so update BOTH deltas in pair B/C
        (pairBC.deltaA, pairBC.deltaB) = updateDeltas(
            pairBC.balanceA, pairAB.balanceB,  // B: old -> new
            pairBC.balanceB, pairBC.balanceB,  // C: unchanged
            pairBC.deltaA, pairBC.deltaB
        );
        pairBC.balanceA = pairAB.balanceB;

        // Step 2: Swap B→C (drain all B)
        uint256 concentratedB_BC = pairBC.balanceA + pairBC.deltaA;
        uint256 concentratedC_BC = pairBC.balanceB + pairBC.deltaB;
        uint256 amountOut_BC = pairBC.balanceB; // Drain all physical balance B
        uint256 amountIn_BC = swapXYC_exactOut(concentratedB_BC, concentratedC_BC, amountOut_BC);

        pairBC.balanceA += amountIn_BC; // This should drain all B: balanceA + amountIn ≈ concentratedB
        pairBC.balanceB -= amountOut_BC;

        // Update liquidity after swap
        concentratedB_BC = pairBC.balanceA + pairBC.deltaA;
        concentratedC_BC = pairBC.balanceB + pairBC.deltaB;
        pairBC.liquidity = Math.sqrt(concentratedB_BC * concentratedC_BC);

        emit log_string("\n=== After B->C swap ===");
        emit log_named_decimal_uint("Balance B", pairBC.balanceA, 18);
        emit log_named_decimal_uint("Balance C", pairBC.balanceB, 18);

        // Update deltas for affected pairs (A/B and B/C)
        // B became 0 in B/C swap, update BOTH deltas in pair A/B
        (pairAB.deltaA, pairAB.deltaB) = updateDeltas(
            pairAB.balanceA, pairAB.balanceA,  // A: unchanged
            pairAB.balanceB, pairBC.balanceA,  // B: old -> new (0)
            pairAB.deltaA, pairAB.deltaB
        );
        pairAB.balanceB = pairBC.balanceA;

        // C decreased in B/C swap, update BOTH deltas in pair A/C
        (pairAC.deltaA, pairAC.deltaB) = updateDeltas(
            pairAC.balanceA, pairAC.balanceA,  // A: unchanged
            pairAC.balanceB, pairBC.balanceB,  // C: old -> new
            pairAC.deltaA, pairAC.deltaB
        );
        pairAC.balanceB = pairBC.balanceB;

        emit log_named_decimal_uint("Updated delta C (AC)", pairAC.deltaB, 18);

        // Step 3: Swap C→A (drain all A)
        uint256 concentratedC_AC = pairAC.balanceB + pairAC.deltaB;
        uint256 concentratedA_AC = pairAC.balanceA + pairAC.deltaA;
        uint256 amountOut_CA = pairAC.balanceA; // Drain all physical balance A
        uint256 amountIn_CA = swapXYC_exactOut(concentratedC_AC, concentratedA_AC, amountOut_CA);

        pairAC.balanceB += amountIn_CA;
        pairAC.balanceA -= amountOut_CA;

        // Update liquidity after swap
        concentratedC_AC = pairAC.balanceB + pairAC.deltaB;
        concentratedA_AC = pairAC.balanceA + pairAC.deltaA;
        pairAC.liquidity = Math.sqrt(concentratedC_AC * concentratedA_AC);

        emit log_string("\n=== After C->A swap ===");
        emit log_named_decimal_uint("Final balance A", pairAC.balanceA, 18);
        emit log_named_decimal_uint("Final balance C", pairAC.balanceB, 18);

        // Update deltas - final state after C->A swap in pair A/C
        (pairAC.deltaA, pairAC.deltaB) = updateDeltas(
            pairAB.balanceA, pairAC.balanceA,  // A: from current AB state -> final AC state
            pairBC.balanceB, pairAC.balanceB,  // C: from current BC state -> final (0)
            pairAC.deltaA, pairAC.deltaB
        );

        emit log_named_decimal_uint("Final delta A (AC)", pairAC.deltaA, 18);
        emit log_named_decimal_uint("Final delta C (AC)", pairAC.deltaB, 18);

        // Calculate concentration ratio before and after
        // Concentration ratio = (balance + delta) / balance
        uint256 concRatioA_initial = (initialBalance + oldDeltaA_AC) * ONE / initialBalance;
        uint256 concRatioA_final = pairAC.balanceA > 0
            ? (pairAC.balanceA + pairAC.deltaA) * ONE / pairAC.balanceA
            : 0;

        emit log_string("\n=== Concentration Analysis ===");
        emit log_named_decimal_uint("Initial conc ratio A", concRatioA_initial, 18);
        emit log_named_decimal_uint("Final conc ratio A", concRatioA_final, 18);

        // Check that concentration ratio is preserved (within 1% tolerance)
        if (pairAC.balanceA > 0) {
            uint256 deviation = concRatioA_final > concRatioA_initial
                ? concRatioA_final - concRatioA_initial
                : concRatioA_initial - concRatioA_final;
            uint256 deviationPercent = deviation * 100 * ONE / concRatioA_initial;

            emit log_named_decimal_uint("Deviation %", deviationPercent, 18);

            assertLt(deviationPercent, ONE, "Concentration ratio should be preserved within 1%");
        }
    }
}
