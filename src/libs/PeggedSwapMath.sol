// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

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

    /// @notice High-precision integer square root with 1e18 fixed-point scaling
    /// @dev Computes sqrt(x) where both x and result are scaled by 1e18
    /// @dev Based on OpenZeppelin's Math.sqrt() with adaptations for fixed-point arithmetic
    /// @dev We want: y such that (y/1e18)² ≈ x/1e18, so y ≈ sqrt(x) * 1e9
    /// @dev Uses bit-shift method for optimal initial guess and exactly 6 Newton iterations
    /// @param x Value to take square root of (scaled by 1e18)
    /// @return y Square root of x (scaled by 1e18)
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) {
            return 0;
        }
        if (x == ONE) {
            return ONE; // sqrt(1e18) = 1e18
        }

        unchecked {
            // We compute: y = sqrt(x) * 1e9 (since sqrt(1e18) = 1e9)
            // This maintains 1e18 scale: if x = n * 1e18, then y = sqrt(n) * 1e18

            // Step 1: Find good initial estimate using bit-shifts (OpenZeppelin method)
            // This finds the smallest power of 2 greater than sqrt(x)
            uint256 xn = 1;
            uint256 aa = x;

            if (aa >= (1 << 128)) {
                aa >>= 128;
                xn <<= 64;
            }
            if (aa >= (1 << 64)) {
                aa >>= 64;
                xn <<= 32;
            }
            if (aa >= (1 << 32)) {
                aa >>= 32;
                xn <<= 16;
            }
            if (aa >= (1 << 16)) {
                aa >>= 16;
                xn <<= 8;
            }
            if (aa >= (1 << 8)) {
                aa >>= 8;
                xn <<= 4;
            }
            if (aa >= (1 << 4)) {
                aa >>= 4;
                xn <<= 2;
            }
            if (aa >= (1 << 2)) {
                xn <<= 1;
            }

            // Refine estimate to middle of interval (reduces error by half)
            xn = (3 * xn) >> 1;

            // Step 2: Newton iterations (exactly 6 for guaranteed convergence)
            // Each iteration: xn = (xn + x / xn) / 2
            // Converges quadratically: error after 6 iterations < 1
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;

            // Step 3: Final correction (ensure we have floor(sqrt(x)))
            y = xn - (xn > x / xn ? 1 : 0);

            // Step 4: Scale to 1e18 (multiply by 1e9 since sqrt(1e18) = 1e9)
            y = y * 1e9;
        }
    }
}
