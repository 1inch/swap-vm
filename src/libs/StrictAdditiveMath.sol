// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StrictAdditiveMath - Gas-optimized math for x^α * y = K AMM
/// @notice Implements strict additive fee model using Balancer-style optimizations
/// @dev Based on Balancer's LogExpMath with precomputed constants and unrolled Taylor series
/// @dev Key optimizations:
///   - Precomputed e^(2^n) constants for decomposition (no loops)
///   - Unrolled Taylor series with fixed terms (no dynamic iteration)
///   - Special high-precision path for ratios close to 1
library StrictAdditiveMath {
    /// @dev Alpha scale - alpha is represented as alpha/ALPHA_SCALE where ALPHA_SCALE = 1e9
    uint256 internal constant ALPHA_SCALE = 1e9;
    
    /// @dev Fixed-point scale (18 decimals)
    int256 internal constant ONE_18 = 1e18;
    int256 internal constant ONE_20 = 1e20;
    int256 internal constant ONE_36 = 1e36;

    /// @dev Domain bounds for natural exponentiation
    int256 internal constant MAX_NATURAL_EXPONENT = 130e18;
    int256 internal constant MIN_NATURAL_EXPONENT = -41e18;

    /// @dev Bounds for ln_36's argument (values close to 1)
    int256 internal constant LN_36_LOWER_BOUND = ONE_18 - 1e17; // 0.9
    int256 internal constant LN_36_UPPER_BOUND = ONE_18 + 1e17; // 1.1

    /// @dev Precomputed e^(2^n) constants for exp decomposition
    int256 internal constant x0 = 128000000000000000000; // 2^7
    int256 internal constant a0 = 38877084059945950922200000000000000000000000000000000000; // e^(x0)
    int256 internal constant x1 = 64000000000000000000; // 2^6
    int256 internal constant a1 = 6235149080811616882910000000; // e^(x1)

    // 20 decimal constants
    int256 internal constant x2 = 3200000000000000000000; // 2^5
    int256 internal constant a2 = 7896296018268069516100000000000000; // e^(x2)
    int256 internal constant x3 = 1600000000000000000000; // 2^4
    int256 internal constant a3 = 888611052050787263676000000; // e^(x3)
    int256 internal constant x4 = 800000000000000000000; // 2^3
    int256 internal constant a4 = 298095798704172827474000; // e^(x4)
    int256 internal constant x5 = 400000000000000000000; // 2^2
    int256 internal constant a5 = 5459815003314423907810; // e^(x5)
    int256 internal constant x6 = 200000000000000000000; // 2^1
    int256 internal constant a6 = 738905609893065022723; // e^(x6)
    int256 internal constant x7 = 100000000000000000000; // 2^0
    int256 internal constant a7 = 271828182845904523536; // e^(x7)
    int256 internal constant x8 = 50000000000000000000; // 2^-1
    int256 internal constant a8 = 164872127070012814685; // e^(x8)
    int256 internal constant x9 = 25000000000000000000; // 2^-2
    int256 internal constant a9 = 128402541668774148407; // e^(x9)
    int256 internal constant x10 = 12500000000000000000; // 2^-3
    int256 internal constant a10 = 113314845306682631683; // e^(x10)
    int256 internal constant x11 = 6250000000000000000; // 2^-4
    int256 internal constant a11 = 106449445891785942956; // e^(x11)

    error StrictAdditiveMathAlphaOutOfRange(uint256 alpha);
    error StrictAdditiveMathInvalidInput();
    error StrictAdditiveMathOverflow();

    /// @notice Calculate (numerator/denominator)^alpha
    /// @param numerator The numerator of the ratio
    /// @param denominator The denominator of the ratio
    /// @param alpha The exponent scaled by ALPHA_SCALE (e.g., 997_000_000 for 0.997)
    /// @return result The result scaled by ONE_18
    function powRatio(
        uint256 numerator,
        uint256 denominator,
        uint256 alpha
    ) internal pure returns (uint256 result) {
        require(denominator > 0, StrictAdditiveMathInvalidInput());
        require(alpha <= ALPHA_SCALE, StrictAdditiveMathAlphaOutOfRange(alpha));
        
        if (numerator == 0) return 0;
        if (alpha == 0) return uint256(ONE_18);
        if (numerator == denominator) return uint256(ONE_18);
        if (alpha == ALPHA_SCALE) return numerator * uint256(ONE_18) / denominator;
        
        // Calculate ratio in 18 decimal fixed point
        int256 ratio = int256(numerator * uint256(ONE_18) / denominator);
        
        // x^α = exp(α * ln(x))
        int256 lnRatio = _ln(ratio);
        int256 exponent = (lnRatio * int256(alpha)) / int256(ALPHA_SCALE);
        
        result = uint256(_exp(exponent));
    }

    /// @notice Calculate (numerator/denominator)^(1/alpha) for ExactOut
    /// @param numerator The numerator of the ratio
    /// @param denominator The denominator of the ratio
    /// @param alpha The exponent denominator scaled by ALPHA_SCALE
    /// @return result The result scaled by ONE_18
    function powRatioInverse(
        uint256 numerator,
        uint256 denominator,
        uint256 alpha
    ) internal pure returns (uint256 result) {
        require(denominator > 0, StrictAdditiveMathInvalidInput());
        require(alpha > 0 && alpha <= ALPHA_SCALE, StrictAdditiveMathAlphaOutOfRange(alpha));
        
        if (numerator == 0) return 0;
        if (numerator == denominator) return uint256(ONE_18);
        if (alpha == ALPHA_SCALE) return numerator * uint256(ONE_18) / denominator;
        
        // Calculate ratio in 18 decimal fixed point
        int256 ratio = int256(numerator * uint256(ONE_18) / denominator);
        
        // x^(1/α) = exp(ln(x) / α) = exp(ln(x) * ALPHA_SCALE / alpha)
        int256 lnRatio = _ln(ratio);
        int256 exponent = (lnRatio * int256(ALPHA_SCALE)) / int256(alpha);
        
        result = uint256(_exp(exponent));
    }

    /// @notice Natural logarithm with 18 decimal fixed point
    /// @dev Uses Balancer's optimized approach with precomputed decomposition
    function _ln(int256 a) internal pure returns (int256) {
        require(a > 0, StrictAdditiveMathInvalidInput());
        
        // Use high-precision path for values close to 1
        if (LN_36_LOWER_BOUND < a && a < LN_36_UPPER_BOUND) {
            return _ln_36(a) / ONE_18;
        }
        
        if (a < ONE_18) {
            // ln(a) = -ln(1/a) for a < 1
            return -_ln((ONE_18 * ONE_18) / a);
        }

        // Decompose using precomputed e^(2^n) constants
        int256 sum = 0;
        
        if (a >= a0 * ONE_18) {
            a /= a0;
            sum += x0;
        }
        if (a >= a1 * ONE_18) {
            a /= a1;
            sum += x1;
        }

        // Convert to 20 decimal precision for remaining terms
        sum *= 100;
        a *= 100;

        if (a >= a2) { a = (a * ONE_20) / a2; sum += x2; }
        if (a >= a3) { a = (a * ONE_20) / a3; sum += x3; }
        if (a >= a4) { a = (a * ONE_20) / a4; sum += x4; }
        if (a >= a5) { a = (a * ONE_20) / a5; sum += x5; }
        if (a >= a6) { a = (a * ONE_20) / a6; sum += x6; }
        if (a >= a7) { a = (a * ONE_20) / a7; sum += x7; }
        if (a >= a8) { a = (a * ONE_20) / a8; sum += x8; }
        if (a >= a9) { a = (a * ONE_20) / a9; sum += x9; }
        if (a >= a10) { a = (a * ONE_20) / a10; sum += x10; }
        if (a >= a11) { a = (a * ONE_20) / a11; sum += x11; }

        // Taylor series for remainder: ln(a) = 2 * (z + z³/3 + z⁵/5 + ...)
        // where z = (a - 1) / (a + 1)
        int256 z = ((a - ONE_20) * ONE_20) / (a + ONE_20);
        int256 z_squared = (z * z) / ONE_20;

        int256 num = z;
        int256 seriesSum = num;

        // Unrolled Taylor series (6 terms sufficient for 18 decimal precision)
        num = (num * z_squared) / ONE_20;
        seriesSum += num / 3;

        num = (num * z_squared) / ONE_20;
        seriesSum += num / 5;

        num = (num * z_squared) / ONE_20;
        seriesSum += num / 7;

        num = (num * z_squared) / ONE_20;
        seriesSum += num / 9;

        num = (num * z_squared) / ONE_20;
        seriesSum += num / 11;

        seriesSum *= 2;

        return (sum + seriesSum) / 100;
    }

    /// @notice High-precision natural log for values close to 1
    function _ln_36(int256 x) private pure returns (int256) {
        x *= ONE_18;

        int256 z = ((x - ONE_36) * ONE_36) / (x + ONE_36);
        int256 z_squared = (z * z) / ONE_36;

        int256 num = z;
        int256 seriesSum = num;

        // Unrolled Taylor series (8 terms for 36 decimal precision)
        num = (num * z_squared) / ONE_36;
        seriesSum += num / 3;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 5;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 7;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 9;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 11;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 13;

        num = (num * z_squared) / ONE_36;
        seriesSum += num / 15;

        return seriesSum * 2;
    }

    /// @notice Exponential function with 18 decimal fixed point
    /// @dev Uses Balancer's optimized decomposition with precomputed constants
    function _exp(int256 x) internal pure returns (int256) {
        require(x >= MIN_NATURAL_EXPONENT && x <= MAX_NATURAL_EXPONENT, StrictAdditiveMathOverflow());

        if (x < 0) {
            return (ONE_18 * ONE_18) / _exp(-x);
        }

        // Decompose using precomputed e^(2^n) constants
        int256 firstAN;
        if (x >= x0) {
            x -= x0;
            firstAN = a0;
        } else if (x >= x1) {
            x -= x1;
            firstAN = a1;
        } else {
            firstAN = 1;
        }

        // Convert to 20 decimal precision
        x *= 100;

        int256 product = ONE_20;

        if (x >= x2) { x -= x2; product = (product * a2) / ONE_20; }
        if (x >= x3) { x -= x3; product = (product * a3) / ONE_20; }
        if (x >= x4) { x -= x4; product = (product * a4) / ONE_20; }
        if (x >= x5) { x -= x5; product = (product * a5) / ONE_20; }
        if (x >= x6) { x -= x6; product = (product * a6) / ONE_20; }
        if (x >= x7) { x -= x7; product = (product * a7) / ONE_20; }
        if (x >= x8) { x -= x8; product = (product * a8) / ONE_20; }
        if (x >= x9) { x -= x9; product = (product * a9) / ONE_20; }

        // Taylor series for remainder: exp(x) = 1 + x + x²/2! + x³/3! + ...
        int256 seriesSum = ONE_20;
        int256 term = x;
        seriesSum += term;

        // Unrolled Taylor series (12 terms sufficient for 18 decimal precision)
        term = ((term * x) / ONE_20) / 2;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 3;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 4;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 5;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 6;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 7;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 8;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 9;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 10;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 11;
        seriesSum += term;

        term = ((term * x) / ONE_20) / 12;
        seriesSum += term;

        return (((product * seriesSum) / ONE_20) * firstAN) / 100;
    }

    /// @notice ExactIn calculation: Δy = y * (1 - (x / (x + Δx))^α)
    function calcExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 alpha
    ) internal pure returns (uint256 amountOut) {
        // (x / (x + Δx))^α
        uint256 ratio = powRatio(balanceIn, balanceIn + amountIn, alpha);
        
        // Δy = y * (ONE_18 - ratio) / ONE_18
        amountOut = balanceOut * (uint256(ONE_18) - ratio) / uint256(ONE_18);
    }

    /// @notice ExactOut calculation: Δx = x * ((y / (y - Δy))^(1/α) - 1)
    function calcExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint256 alpha
    ) internal pure returns (uint256 amountIn) {
        require(amountOut < balanceOut, StrictAdditiveMathInvalidInput());
        
        // (y / (y - Δy))^(1/α)
        uint256 ratio = powRatioInverse(balanceOut, balanceOut - amountOut, alpha);
        
        // Δx = x * (ratio - ONE_18) / ONE_18 (ceiling)
        amountIn = Math.ceilDiv(balanceIn * (ratio - uint256(ONE_18)), uint256(ONE_18));
    }
}
