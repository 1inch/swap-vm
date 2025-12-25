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
    /// @param u Normalized x value (x/X₀) scaled by 1e18
    /// @param a Linear width parameter scaled by 1e18
    /// @param invariantC Target invariant constant scaled by 1e18
    /// @return v Normalized y value (y/Y₀) scaled by 1e18
    function solve(uint256 u, uint256 a, uint256 invariantC) internal pure returns (uint256 v) {
        // Calculate √u with safe handling
        uint256 sqrtU = Math.sqrt(u * ONE);

        // a * u / ONE - safe: a ≤ 2e27, u ≤ 2e27 → 4e54 < 1e77
        uint256 au = a * u / ONE;

        // Calculate rightSide = c - √u - au
        // Need to check: invariantC >= sqrtU + au
        uint256 sqrtUPlusAu = sqrtU + au;
        require(invariantC >= sqrtUPlusAu, PeggedSwapMathInvalidInput());

        uint256 rightSide = invariantC - sqrtUPlusAu;

        if (a == 0) {
            // Special case: a = 0
            // Equation becomes: √v = rightSide
            // So: v = rightSide²
            v = (rightSide * rightSide) / ONE;
            return v;
        }

        // General case: aw² + w - rightSide = 0
        // Quadratic formula: w = (-1 ± √(1 + 4a·rightSide)) / (2a)
        // We want the positive root

        // 4 * a * rightSide / ONE - safe: 4a ≤ 8e27, rightSide ≤ 2e27 → 16e54 < 1e77
        uint256 fourARightSide = 4 * a * rightSide / ONE;

        // Calculate discriminant: 1 + 4a * rightSide
        uint256 discriminant = ONE + fourARightSide;

        // Calculate √discriminant with round UP (key for symmetry)
        uint256 sqrtDiscriminant = Math.sqrt(discriminant * ONE, Math.Rounding.Ceil);

        // w = (-1 + √discriminant) / (2a)
        // sqrtDiscriminant should always be >= 1 since discriminant >= 1
        require(sqrtDiscriminant >= ONE, PeggedSwapMathNoSolution());

        // numerator = sqrtDiscriminant - 1 (in 1e27 scale)
        uint256 numerator = sqrtDiscriminant - ONE;

        // denominator = 2a (in 1e27 scale)
        uint256 denominator = 2 * a;

        // numerator * ONE / denominator - safe: numerator ≤ 2e27, ONE = 1e27 → 2e54
        uint256 w = numerator * ONE / denominator;

        // w² / ONE - safe: w ≤ 2e27 → 4e54 < 1e77
        v = w * w / ONE;
    }

}
