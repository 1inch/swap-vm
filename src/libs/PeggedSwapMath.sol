// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PeggedSwapMath - Complete math library for PeggedSwap
/// @notice Provides all mathematical operations for PeggedSwap curve (p=0.5)
/// @notice Formula: √u + √v + A(u + v) = C
/// @dev Uses 1e27 scale for higher precision (reduces rounding error by ~10^9)
library PeggedSwapMath {
    uint256 internal constant ONE = 1e27;

    error PeggedSwapMathNoSolution();
    error PeggedSwapMathInvalidInput();

    /// @notice Calculate invariant value: √u + √v + A(u + v)
    /// @param u Normalized x value (x/X₀) scaled by ONE
    /// @param v Normalized y value (y/Y₀) scaled by ONE
    /// @param a Linear width parameter scaled by ONE
    /// @return Invariant value scaled by sqrt(ONE)
    function invariant(uint256 u, uint256 v, uint256 a) internal pure returns (uint256) {
        uint256 sqrtU = Math.sqrt(u * ONE);
        uint256 sqrtV = Math.sqrt(v * ONE);
        // a * (u + v) / ONE - safe: a ≤ 2e27, u+v ≤ 2e27 → 4e54 < 1e77
        uint256 linearTerm = a * (u + v) / ONE;
        return sqrtU + sqrtV + linearTerm;
    }

    /// @notice Calculate invariant from actual reserves
    /// @param x Current x reserve
    /// @param y Current y reserve
    /// @param x0 Initial X reserve (normalization factor)
    /// @param y0 Initial Y reserve (normalization factor)
    /// @param a Linear width parameter scaled by ONE
    /// @return Invariant value scaled by sqrt(ONE)
    function invariantFromReserves(
        uint256 x,
        uint256 y,
        uint256 x0,
        uint256 y0,
        uint256 a
    ) internal pure returns (uint256) {
        // x * ONE / x0 - safe: x ≤ 1e24 (huge reserve), ONE = 1e27 → 1e51 < 1e77
        uint256 u = x * ONE / x0;
        uint256 v = y * ONE / y0;
        return invariant(u, v, a);
    }

    /// @notice Solve for v analytically using square root curve (p=0.5)
    /// @dev √u + √v + a(u + v) = c
    /// @dev Rearranges to: √v + av = c - √u - au
    /// @dev Let w = √v, then: aw² + w = [c - √u - au]
    /// @dev Quadratic in w: aw² + w - rightSide = 0
    /// @dev Solution: w = (-1 + √(1 + 4a * rightSide)) / (2a)
    /// @param u Normalized x value (x/X₀) scaled by ONE
    /// @param a Linear width parameter scaled by ONE
    /// @param invariantC Target invariant constant scaled by sqrt(ONE)
    /// @return v Normalized y value (y/Y₀) scaled by ONE
    function solve(uint256 u, uint256 a, uint256 invariantC) internal pure returns (uint256 v) {
        // a * u / ONE - safe: a ≤ 2e27, u ≤ 2e27 → 4e54 < 1e77
        uint256 invariantU = Math.sqrt(u * ONE) + a * u / ONE;
        require(invariantC >= invariantU, PeggedSwapMathInvalidInput());
        return solveWithInvariant(invariantU, a, invariantC);
    }

    /// @notice solve() variant for callers that already computed the u-side invariant term (√u + au)
    /// @dev Identical to solve() but skips recomputing √u + au; lets a caller that already has it
    ///      (e.g. from a capacity check √u + au >= c) avoid the expensive sqrt and the extra adds.
    /// @dev PRECONDITION: invariantC >= invariantU. Callers must guarantee this (e.g. by a prior
    ///      capacity check); otherwise the subtraction below reverts on underflow.
    /// @param invariantU u-side invariant contribution = √u + au, scaled by sqrt(ONE)
    /// @param a Linear width parameter scaled by ONE
    /// @param invariantC Target invariant constant scaled by sqrt(ONE)
    /// @return v Normalized y value (y/Y₀) scaled by ONE
    function solveWithInvariant(uint256 invariantU, uint256 a, uint256 invariantC) internal pure returns (uint256 v) {
        // rightSide = c - (√u + au); precondition invariantC >= invariantU holds (see @dev)
        uint256 rightSide = invariantC - invariantU;

        if (a == 0) {
            // Equation becomes: √v = rightSide, so v = rightSide²
            v = (rightSide * rightSide) / ONE;
            return v;
        }

        // General case: aw² + w - rightSide = 0
        // Quadratic formula: w = (-1 + √(1 + 4a·rightSide)) / (2a)
        // (we want the positive root)
        //
        // NUMERICAL STABILITY FIX:
        // The standard formula w = (-1 + √D) / (2a) suffers from catastrophic cancellation
        // when a is small: D = 1 + 4aR/ONE ≈ 1, so √D ≈ 1, and numerator √D - 1 ≈ 0.
        //
        // We use the algebraically equivalent formula derived by rationalizing:
        // w = (-1 + √D) / (2a) * (1 + √D) / (1 + √D)
        //   = (D - 1) / (2a * (1 + √D))
        //   = (4aR/ONE) / (2a * (1 + √D))
        //   = 2R / (1 + √D)
        //
        // This form is stable for all values of a, including when a → 0.

        // 4 * a * rightSide / ONE - safe: 4a ≤ 8e27, rightSide ≤ 2e27 → 16e54 < 1e77
        uint256 fourARightSide = 4 * a * rightSide / ONE;

        uint256 discriminant = ONE + fourARightSide;

        uint256 sqrtDiscriminant = Math.sqrt(discriminant * ONE, Math.Rounding.Ceil);

        require(sqrtDiscriminant >= ONE, PeggedSwapMathNoSolution());

        uint256 denominator = ONE + sqrtDiscriminant;

        uint256 w = 2 * rightSide * ONE / denominator;

        // w² / ONE - safe: w ≤ 2e27 → 4e54 < 1e77
        v = w * w / ONE;
    }

}
