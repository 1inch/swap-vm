// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StrictAdditiveMath - Math library for x^α * y = K AMM with fee reinvested inside pricing
/// @notice Implements strict additive fee model where: y * Ψ(x) = K with Ψ(x) = x^α
/// @dev Based on the paper "Strict-Additive Fees Reinvested Inside Pricing for AMMs"
/// @dev Key property: Split invariance - swapping (a+b) equals swapping a then b
/// @dev Uses fixed-point arithmetic with 1e27 precision for intermediate calculations
library StrictAdditiveMath {
    /// @dev Precision scale for fixed-point math (1e27 for high precision)
    uint256 internal constant ONE = 1e27;
    
    /// @dev Alpha scale - alpha is represented as alpha/ALPHA_SCALE where ALPHA_SCALE = 1e9
    /// @dev Example: alpha = 0.997 is stored as 997_000_000
    uint256 internal constant ALPHA_SCALE = 1e9;
    
    /// @dev Maximum number of iterations for the power calculation
    uint256 internal constant MAX_ITERATIONS = 100;
    
    /// @dev Convergence threshold for Newton-Raphson (in ONE scale)
    uint256 internal constant CONVERGENCE_THRESHOLD = 1e9; // 1e-18 in ONE scale

    error StrictAdditiveMathAlphaOutOfRange(uint256 alpha);
    error StrictAdditiveMathInvalidInput();
    error StrictAdditiveMathNoConvergence();
    error StrictAdditiveMathOverflow();

    /// @notice Calculate ratio^alpha using binary exponentiation with fixed-point
    /// @dev For ratio = numerator/denominator, calculates (numerator/denominator)^alpha
    /// @dev Uses the identity: r^α ≈ r^(n/d) where alpha = n/d in ALPHA_SCALE
    /// @param numerator The numerator of the ratio
    /// @param denominator The denominator of the ratio (must be > 0)
    /// @param alpha The exponent scaled by ALPHA_SCALE (e.g., 997_000_000 for 0.997)
    /// @return result The result scaled by ONE
    function powRatio(
        uint256 numerator,
        uint256 denominator,
        uint256 alpha
    ) internal pure returns (uint256 result) {
        require(denominator > 0, StrictAdditiveMathInvalidInput());
        require(alpha <= ALPHA_SCALE, StrictAdditiveMathAlphaOutOfRange(alpha));
        
        if (numerator == 0) return 0;
        if (alpha == 0) return ONE;
        if (alpha == ALPHA_SCALE) return numerator * ONE / denominator;
        if (numerator == denominator) return ONE;
        
        // For r^α where r = numerator/denominator and α = alpha/ALPHA_SCALE
        // We use: r^α = exp(α * ln(r))
        
        // Calculate ln(r) = ln(numerator/denominator) = ln(numerator) - ln(denominator)
        // Using fixed-point logarithm
        int256 lnR = _ln(numerator) - _ln(denominator);
        
        // Calculate α * ln(r) with proper scaling
        // lnR is in ONE scale, alpha is in ALPHA_SCALE
        int256 exponent = (lnR * int256(alpha)) / int256(ALPHA_SCALE);
        
        // Calculate exp(α * ln(r))
        result = _exp(exponent);
    }
    
    /// @notice Calculate ratio^(1/alpha) for ExactOut calculations
    /// @dev For ratio = numerator/denominator, calculates (numerator/denominator)^(1/alpha)
    /// @param numerator The numerator of the ratio
    /// @param denominator The denominator of the ratio (must be > 0)
    /// @param alpha The exponent denominator scaled by ALPHA_SCALE
    /// @return result The result scaled by ONE
    function powRatioInverse(
        uint256 numerator,
        uint256 denominator,
        uint256 alpha
    ) internal pure returns (uint256 result) {
        require(denominator > 0, StrictAdditiveMathInvalidInput());
        require(alpha > 0 && alpha <= ALPHA_SCALE, StrictAdditiveMathAlphaOutOfRange(alpha));
        
        if (numerator == 0) return 0;
        if (alpha == ALPHA_SCALE) return numerator * ONE / denominator;
        if (numerator == denominator) return ONE;
        
        // For r^(1/α) where r = numerator/denominator and α = alpha/ALPHA_SCALE
        // We use: r^(1/α) = exp((1/α) * ln(r)) = exp(ln(r) * ALPHA_SCALE / alpha)
        
        // Calculate ln(r)
        int256 lnR = _ln(numerator) - _ln(denominator);
        
        // Calculate ln(r) / α with proper scaling
        // lnR is in ONE scale, we divide by alpha and multiply by ALPHA_SCALE
        int256 exponent = (lnR * int256(ALPHA_SCALE)) / int256(alpha);
        
        // Calculate exp(ln(r) / α)
        result = _exp(exponent);
    }

    /// @notice Natural logarithm using Taylor series
    /// @dev Input: x as raw uint256
    /// @dev Output: ln(x) scaled by ONE (1e27)
    /// @dev Uses ln(x) = ln(x/ONE * ONE) = ln(x/ONE) + ln(ONE)
    function _ln(uint256 x) internal pure returns (int256) {
        require(x > 0, StrictAdditiveMathInvalidInput());
        
        // Scale x to be around ONE for better precision
        // Find n such that x * 2^n is in range [ONE, 2*ONE]
        int256 scale = 0;
        uint256 scaledX = x;
        
        // Scale up if too small
        while (scaledX < ONE && scale > -256) {
            scaledX = scaledX * 2;
            scale -= 1;
        }
        
        // Scale down if too large
        while (scaledX >= 2 * ONE && scale < 256) {
            scaledX = scaledX / 2;
            scale += 1;
        }
        
        // Now scaledX is approximately in [ONE, 2*ONE]
        // ln(x) = ln(scaledX) + scale * ln(2)
        
        // Calculate ln(scaledX) using ln(1+t) = t - t²/2 + t³/3 - ...
        // where t = (scaledX - ONE) / ONE
        
        // For scaledX in [ONE, 2*ONE], t is in [0, 1]
        int256 t = (int256(scaledX) - int256(ONE));
        
        // Taylor series: ln(1+t) = t - t²/2 + t³/3 - t⁴/4 + ...
        int256 result = 0;
        int256 term = t;  // t^1 / 1
        
        for (uint256 i = 1; i <= 50 && (term > int256(CONVERGENCE_THRESHOLD) || term < -int256(CONVERGENCE_THRESHOLD)); i++) {
            if (i % 2 == 1) {
                result += term / int256(i);
            } else {
                result -= term / int256(i);
            }
            term = (term * t) / int256(ONE);
        }
        
        // Add scale * ln(2)
        // ln(2) ≈ 0.693147180559945... in ONE scale
        int256 LN_2 = 693147180559945309417232121458176568 * int256(ONE) / 1e36;
        
        result += scale * LN_2;
        
        return result;
    }

    /// @notice Exponential function using Taylor series
    /// @dev Input: x scaled by ONE
    /// @dev Output: exp(x) scaled by ONE
    function _exp(int256 x) internal pure returns (uint256) {
        // Handle edge cases
        if (x == 0) return ONE;
        
        // For very negative x, result is close to 0
        if (x < -63 * int256(ONE)) return 0;
        
        // For very positive x, overflow
        require(x < 130 * int256(ONE), StrictAdditiveMathOverflow());
        
        // Reduce x to range [-1, 1] by using exp(x) = exp(x/n)^n
        // We use exp(x) = exp(x - k*ln(2)) * 2^k
        int256 LN_2 = 693147180559945309417232121458176568 * int256(ONE) / 1e36;
        
        int256 k = x / LN_2;
        int256 r = x - k * LN_2;  // r is in [-ln(2), ln(2)]
        
        // Calculate exp(r) using Taylor series: exp(r) = 1 + r + r²/2! + r³/3! + ...
        int256 result = int256(ONE);
        int256 term = int256(ONE);
        
        for (uint256 i = 1; i <= 30; i++) {
            term = (term * r) / (int256(ONE) * int256(i));
            result += term;
            
            if (term > -int256(CONVERGENCE_THRESHOLD) && term < int256(CONVERGENCE_THRESHOLD)) {
                break;
            }
        }
        
        // Multiply by 2^k
        if (k >= 0) {
            if (k > 88) return type(uint256).max; // Overflow protection
            result = result << uint256(k);
        } else {
            result = result >> uint256(-k);
        }
        
        return result >= 0 ? uint256(result) : 0;
    }

    /// @notice ExactIn calculation: Δy = y * (1 - (x / (x + Δx))^α)
    /// @param balanceIn Current balance of input token (x)
    /// @param balanceOut Current balance of output token (y)
    /// @param amountIn Amount of input token (Δx)
    /// @param alpha The alpha parameter scaled by ALPHA_SCALE
    /// @return amountOut Amount of output token (Δy)
    function calcExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 alpha
    ) internal pure returns (uint256 amountOut) {
        // y' = y * (x / (x + Δx))^α
        // Δy = y - y' = y * (1 - (x / (x + Δx))^α)
        
        // Calculate (x / (x + Δx))^α
        uint256 ratio = powRatio(balanceIn, balanceIn + amountIn, alpha);
        
        // Δy = y * (ONE - ratio) / ONE
        // Use floor division to protect maker
        amountOut = balanceOut * (ONE - ratio) / ONE;
    }

    /// @notice ExactOut calculation: Δx = x * ((y / (y - Δy))^(1/α) - 1)
    /// @param balanceIn Current balance of input token (x)
    /// @param balanceOut Current balance of output token (y)
    /// @param amountOut Amount of output token (Δy)
    /// @param alpha The alpha parameter scaled by ALPHA_SCALE
    /// @return amountIn Amount of input token (Δx)
    function calcExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint256 alpha
    ) internal pure returns (uint256 amountIn) {
        require(amountOut < balanceOut, StrictAdditiveMathInvalidInput());
        
        // Δx = x * ((y / (y - Δy))^(1/α) - 1)
        
        // Calculate (y / (y - Δy))^(1/α)
        uint256 ratio = powRatioInverse(balanceOut, balanceOut - amountOut, alpha);
        
        // Δx = x * (ratio - ONE) / ONE
        // Use ceiling division to protect maker
        amountIn = Math.ceilDiv(balanceIn * (ratio - ONE), ONE);
    }
}
