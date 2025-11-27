// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

/// @title PeggedSwapMath - Complete math library for PeggedSwap
/// @notice Provides all mathematical operations for PeggedSwap curve (p=0.5)
/// @notice Formula: √u + √v + A(u + v) = C
library PeggedSwapMath {
    uint256 private constant ONE = 1e18;

    error PeggedSwapMathNoSolution();
    error PeggedSwapMathInvalidInput();

    /// @notice Calculate invariant value: √u + √v + A(u + v)
    /// @param u Normalized x value (x/X₀) scaled by 1e18
    /// @param v Normalized y value (y/Y₀) scaled by 1e18
    /// @param a Linear width parameter scaled by 1e18
    /// @return Invariant value scaled by 1e18
    function invariant(uint256 u, uint256 v, uint256 a) internal pure returns (uint256) {
        uint256 sqrtU = sqrt(u);
        uint256 sqrtV = sqrt(v);
        uint256 linearTerm = (a * (u + v)) / ONE;
        return sqrtU + sqrtV + linearTerm;
    }

    /// @notice Calculate invariant from actual reserves
    /// @param x Current x reserve
    /// @param y Current y reserve
    /// @param x0 Initial X reserve (normalization factor)
    /// @param y0 Initial Y reserve (normalization factor)
    /// @param a Linear width parameter scaled by 1e18
    /// @return Invariant value scaled by 1e18
    function invariantFromReserves(
        uint256 x,
        uint256 y,
        uint256 x0,
        uint256 y0,
        uint256 a
    ) internal pure returns (uint256) {
        uint256 u = (x * ONE) / x0;
        uint256 v = (y * ONE) / y0;
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
        uint256 sqrtU = sqrt(u);

        // Calculate au safely
        uint256 au = (a * u) / ONE;

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

        // Calculate 4a * rightSide carefully to avoid overflow
        uint256 fourARightSide = (4 * a * rightSide) / ONE;

        // Calculate discriminant: 1 + 4a * rightSide
        uint256 discriminant = ONE + fourARightSide;

        // Calculate √discriminant
        uint256 sqrtDiscriminant = sqrt(discriminant);

        // w = (-1 + √discriminant) / (2a)
        // sqrtDiscriminant should always be >= 1 since discriminant >= 1
        require(sqrtDiscriminant >= ONE, PeggedSwapMathNoSolution());

        // numerator = sqrtDiscriminant - 1 (in 1e18 scale)
        uint256 numerator = sqrtDiscriminant - ONE;

        // denominator = 2a (in 1e18 scale)
        uint256 denominator = 2 * a;

        // w = numerator * 1e18 / denominator
        uint256 w = (numerator * ONE) / denominator;

        // v = w² (both scaled by 1e18)
        v = (w * w) / ONE;
    }

    /// @notice Integer square root using Newton's method with proper 1e18 scaling
    /// @dev Computes sqrt(x) where both x and result are scaled by 1e18
    /// @dev We need: y such that (y/1e18)² = x/1e18, so y² = x * 1e18
    /// @dev To avoid overflow, we compute: y = sqrt(x) * 1e9 (since sqrt(1e18) = 1e9)
    /// @param x Value to take square root of (scaled by 1e18)
    /// @return y Square root of x (scaled by 1e18)
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        if (x == ONE) return ONE;

        // Compute sqrt(x * 1e18), avoid overflow, compute sqrt(x) first, then adjust scaling
        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        // Result scaled by 1e18, so multiply by 1e9
        // result = y * 1e9 = sqrt(realValue) * 1e18
        y = y * 1e9;
    }
}
