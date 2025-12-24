// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";

/**
 * @title PeggedSwapDebug
 * @notice Debug test to trace intermediate values in PeggedSwap calculations
 */
contract PeggedSwapDebug is Test {
    uint256 constant ONE = PeggedSwapMath.ONE;

    function test_DebugDifferentDecimals() public view {
        // Config matching LargeDifferentDecimals test
        uint256 balanceA = 1_000_000e18;  // 1M tokens, 18 dec
        uint256 balanceB = 1_000_000e6;   // 1M tokens, 6 dec
        uint256 configX0 = 1_000_000e18;
        uint256 configY0 = 1_000_000e18;
        uint256 linearWidth = 0.8e27;
        uint256 rateIn = 1;      // TokenA (18 dec)
        uint256 rateOut = 1e12;  // TokenB (6 dec)

        uint256 amountIn = 1000e18;  // 1K tokens

        console.log("=== INITIAL STATE ===");
        console.log("balanceA (raw):", balanceA);
        console.log("balanceB (raw):", balanceB);
        console.log("rateIn:", rateIn);
        console.log("rateOut:", rateOut);
        console.log("configX0:", configX0);
        console.log("configY0:", configY0);
        console.log("amountIn:", amountIn);

        // Scale balances
        uint256 x0 = balanceA * rateIn;
        uint256 y0 = balanceB * rateOut;
        console.log("\n=== SCALED BALANCES ===");
        console.log("x0 (scaled):", x0);
        console.log("y0 (scaled):", y0);

        // Calculate invariant
        uint256 invariant = PeggedSwapMath.invariantFromReserves(x0, y0, configX0, configY0, linearWidth);
        console.log("invariant:", invariant);

        console.log("\n=== EXACTIN CALCULATION ===");
        // ExactIn
        uint256 x1 = x0 + amountIn * rateIn;
        console.log("x1:", x1);

        uint256 u1 = x1 * ONE / configX0;
        console.log("u1:", u1);

        uint256 v1_exactIn = PeggedSwapMath.solve(u1, linearWidth, invariant);
        console.log("v1 (from solve):", v1_exactIn);

        uint256 y1_exactIn = Math.ceilDiv(v1_exactIn * configY0, ONE);
        console.log("y1 (ceilDiv):", y1_exactIn);

        uint256 deltaY = y0 - y1_exactIn;
        console.log("deltaY (y0 - y1):", deltaY);

        uint256 amountOut = deltaY / rateOut;  // floor
        console.log("amountOut (floor):", amountOut);

        uint256 remainder = deltaY % rateOut;
        console.log("remainder (deltaY % rateOut):", remainder);

        console.log("\n=== EXACTOUT CALCULATION (with amountOut from ExactIn) ===");
        // ExactOut with same amountOut
        uint256 y1_exactOut = y0 - amountOut * rateOut;
        console.log("y1_exactOut:", y1_exactOut);
        console.log("y1_exactIn:", y1_exactIn);
        console.log("y1 diff (exactOut - exactIn):", y1_exactOut - y1_exactIn);

        uint256 v1_exactOut = y1_exactOut * ONE / configY0;  // floor
        console.log("v1_exactOut (floor):", v1_exactOut);
        console.log("v1_exactIn:", v1_exactIn);
        if (v1_exactOut >= v1_exactIn) {
            console.log("v1 diff (exactOut - exactIn):", v1_exactOut - v1_exactIn);
        } else {
            console.log("v1 diff (exactIn - exactOut):", v1_exactIn - v1_exactOut);
        }

        uint256 u1_exactOut = PeggedSwapMath.solve(v1_exactOut, linearWidth, invariant);
        console.log("u1_exactOut:", u1_exactOut);
        console.log("u1_exactIn:", u1);
        if (u1_exactOut >= u1) {
            console.log("u1 diff (exactOut - exactIn):", u1_exactOut - u1);
        } else {
            console.log("u1 diff (exactIn - exactOut):", u1 - u1_exactOut);
        }

        uint256 x1_exactOut = Math.ceilDiv(u1_exactOut * configX0, ONE);
        console.log("x1_exactOut (ceilDiv):", x1_exactOut);
        console.log("x1_exactIn:", x1);
        if (x1_exactOut >= x1) {
            console.log("x1 diff (exactOut - exactIn):", x1_exactOut - x1);
        } else {
            console.log("x1 diff (exactIn - exactOut):", x1 - x1_exactOut);
        }

        uint256 amountIn_back = Math.ceilDiv(x1_exactOut - x0, rateIn);
        console.log("\n=== RESULT ===");
        console.log("amountIn (original):", amountIn);
        console.log("amountIn_back:", amountIn_back);
        if (amountIn >= amountIn_back) {
            console.log("diff (original - back):", amountIn - amountIn_back);
        } else {
            console.log("diff (back - original):", amountIn_back - amountIn);
        }
    }
}
