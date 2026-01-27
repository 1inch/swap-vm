// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/**
 * @title StatelessSwapMath - Dual Invariant Curve AMM with Fee Reinvestment
 * @notice Implements AMM using direction-dependent invariant curves for automatic fee reinvestment
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 *                                  CORE CONCEPT
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * Uses the invariant curve: out · in^α = K
 *
 * Where:
 *   • α = 1 - φ  (φ is fee rate, e.g., 0.003 = 0.3%)
 *   • in = balanceIn (current input reserve)
 *   • out = balanceOut (current output reserve)
 *   • K = balanceOut · balanceIn^α (computed from current reserves)
 *
 * Key insight: By always applying the exponent α to the INPUT side,
 * fees are reinvested into the pool regardless of swap direction.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 *                              SWAP FORMULAS
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * ExactIn (given Δin, compute Δout):
 *   From invariant: (out - Δout) · (in + Δin)^α = out · in^α
 *
 *   Δout = out · (1 - (in / (in + Δin))^α)
 *
 * ExactOut (given Δout, compute Δin):
 *   From invariant: (out - Δout) · (in + Δin)^α = out · in^α
 *
 *   Δin = in · ((out / (out - Δout))^(1/α) - 1)
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 *                              FEE REINVESTMENT PROOF
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * After a swap:
 *   in' = in + Δin
 *   out' = out - Δout = out · (in/in')^α
 *
 * Product K_product = in · out changes:
 *   K'_product / K_product = (in'/in)^(1-α)
 *
 * For α < 1 (fee > 0) and in' > in:
 *   K'_product > K_product
 *
 * The pool's liquidity (measured by in·out) GROWS after each swap.
 * This growth represents the reinvested fees.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 *                           WHY BOTH DIRECTIONS WORK
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * For X→Y swap: Uses curve out·in^α = K where in=X, out=Y
 *   → Fees reinvested (K_product grows)
 *
 * For Y→X swap: Uses curve out·in^α = K where in=Y, out=X
 *   → Fees reinvested (K_product grows)
 *
 * The exponent α always applies to whichever token is being INPUT,
 * ensuring fees are captured from both swap directions.
 */
library StatelessSwapMath {
    uint256 internal constant ONE = 1e18;  // Fixed-point 1.0
    uint256 internal constant LN2 = 693147180559945309;  // ln(2) in 1e18
    uint256 internal constant LN_SQRT2 = 346573590279972654;  // ln(√2) = ln(2)/2

    error StatelessSwapMathZeroInput();
    error StatelessSwapMathInsufficientOutput();
    error StatelessSwapMathInvalidAlpha();

    /**
     * @notice Calculate output amount for exactIn swap using invariant curve
     * @dev Formula: Δout = out · (1 - (in / (in + Δin))^α)
     * @param balanceIn Current input token reserve
     * @param balanceOut Current output token reserve
     * @param amountIn Input amount
     * @param alpha Fee-adjusted exponent (1e18 scale, e.g., 0.997e18 for 0.3% fee)
     * @return amountOut Output amount
     */
    function swapExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 alpha
    ) internal pure returns (uint256 amountOut) {
        require(balanceIn > 0 && balanceOut > 0 && amountIn > 0, StatelessSwapMathZeroInput());
        require(alpha > 0 && alpha <= ONE, StatelessSwapMathInvalidAlpha());

        // Special case: alpha = 1 (no fee) -> standard constant product
        if (alpha == ONE) {
            return balanceOut * amountIn / (balanceIn + amountIn);
        }

        // ratio = in / (in + Δin), scaled to 1e18
        uint256 newBalanceIn = balanceIn + amountIn;
        uint256 ratio = balanceIn * ONE / newBalanceIn;

        // ratio^alpha using exp(alpha * ln(ratio))
        uint256 ratioAlpha = _pow(ratio, alpha);

        // Δout = out * (1 - ratio^alpha)
        // For α < 1: ratio^α > ratio, so we get less output (fee)
        if (ratioAlpha >= ONE) {
            // Due to precision, if ratioAlpha >= 1, no output
            return 0;
        }
        amountOut = balanceOut * (ONE - ratioAlpha) / ONE;
    }

    /**
     * @notice Calculate input amount for exactOut swap using invariant curve
     * @dev Formula: Δin = in · ((out / (out - Δout))^(1/α) - 1)
     * @dev IMPORTANT: Includes safety margin to ensure ExactIn(ExactOut(dy)) >= dy
     *      The ln/exp approximations have precision errors that could otherwise
     *      cause ExactOut to underestimate the required input.
     * @param balanceIn Current input token reserve
     * @param balanceOut Current output token reserve
     * @param amountOut Desired output amount
     * @param alpha Fee-adjusted exponent (1e18 scale)
     * @return amountIn Required input amount (rounded up with safety margin)
     */
    function swapExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint256 alpha
    ) internal pure returns (uint256 amountIn) {
        require(balanceIn > 0 && balanceOut > 0 && amountOut > 0, StatelessSwapMathZeroInput());
        require(amountOut < balanceOut, StatelessSwapMathInsufficientOutput());
        require(alpha > 0 && alpha <= ONE, StatelessSwapMathInvalidAlpha());

        // Special case: alpha = 1 (no fee) -> standard constant product
        if (alpha == ONE) {
            // Ceiling division: (a + b - 1) / b
            return (balanceIn * amountOut + balanceOut - amountOut - 1) / (balanceOut - amountOut) + 1;
        }

        // ratio = out / (out - Δout), which is > 1
        uint256 newBalanceOut = balanceOut - amountOut;
        uint256 ratio = balanceOut * ONE / newBalanceOut;

        // ratio^(1/alpha) - we need inverse exponent
        // 1/alpha > 1 when alpha < 1
        uint256 invAlpha = ONE * ONE / alpha;  // 1/alpha in 1e18 scale
        uint256 ratioInvAlpha = _pow(ratio, invAlpha);

        // Δin = in * (ratio^(1/α) - 1)
        if (ratioInvAlpha <= ONE) {
            // Due to precision issues, fallback to constant product
            return (balanceIn * amountOut + balanceOut - amountOut - 1) / (balanceOut - amountOut) + 1;
        }

        amountIn = balanceIn * (ratioInvAlpha - ONE) / ONE;

        // Round up to favor maker
        if (balanceIn * (ratioInvAlpha - ONE) % ONE > 0) {
            amountIn += 1;
        }

        // CRITICAL: Verify that ExactIn(amountIn) >= amountOut
        // Due to ln/exp approximation errors, we may need to add more input
        // to ensure the invariant: ExactOut(dy) produces enough input to get dy via ExactIn
        uint256 verifyOutput = swapExactIn(balanceIn, balanceOut, amountIn, alpha);

        // If verification fails, increment amountIn until it passes
        // We also add small buffer to ensure strict inequality (verifyOutput > amountOut)
        // This is bounded because more input always produces more output
        uint256 maxIterations = 100;  // Safety limit
        while (verifyOutput <= amountOut && maxIterations > 0) {
            // Estimate how much more input we need
            uint256 deficit = amountOut > verifyOutput ? amountOut - verifyOutput : 1;
            uint256 extraIn = deficit * balanceIn / balanceOut;
            // Always add at least 1, or proportional buffer for larger amounts
            if (extraIn < amountIn / 1e12) extraIn = amountIn / 1e12;  // ~1e-12 relative buffer
            if (extraIn == 0) extraIn = 1;

            amountIn += extraIn;
            verifyOutput = swapExactIn(balanceIn, balanceOut, amountIn, alpha);
            maxIterations--;
        }
    }

    /**
     * @notice Convert fee in BPS to alpha parameter
     * @dev alpha = 1 - fee, where fee is in 1e18 scale
     * @param feeBps Fee in basis points (e.g., 30 for 0.3%)
     * @return alpha The exponent parameter (1e18 scale)
     */
    function feeToAlpha(uint256 feeBps) internal pure returns (uint256 alpha) {
        // feeBps of 30 means 0.3% = 0.003
        // In 1e18: 30 * 1e18 / 10000 = 3e15
        uint256 feeScaled = feeBps * ONE / 10000;
        require(feeScaled < ONE, StatelessSwapMathInvalidAlpha());
        alpha = ONE - feeScaled;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    //                              MATH HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Compute base^exp where both are in 1e18 fixed-point
     * @dev Uses exp(exp * ln(base)) with improved range reduction
     * @param base The base (1e18 scale, must be > 0)
     * @param exponent The exponent (1e18 scale)
     * @return result = base^exp in 1e18 scale
     */
    function _pow(uint256 base, uint256 exponent) internal pure returns (uint256) {
        if (exponent == 0) return ONE;
        if (exponent == ONE) return base;
        if (base == ONE) return ONE;
        if (base == 0) return 0;

        // For base very close to 1, use binomial approximation:
        // (1+u)^α ≈ 1 + αu + α(α-1)u²/2 + ...
        // This is accurate when |u| << 1
        if (base > ONE * 95 / 100 && base < ONE * 105 / 100) {
            // base is within 5% of 1.0 - use quadratic approximation
            int256 u = int256(base) - int256(ONE);  // u = base - 1 (can be negative)
            int256 alpha = int256(exponent);

            // Term 1: α*u (in fixed-point)
            int256 term1 = (alpha * u) / int256(ONE);

            // Term 2: α*(α-1)*u²/2 (in fixed-point)
            // First compute u² in fixed-point
            int256 u2 = (u * u) / int256(ONE);
            // Then α*(α-1) in fixed-point (note: α-1 is negative when α < 1)
            int256 alphaCoeff = (alpha * (alpha - int256(ONE))) / int256(ONE);
            // Finally term2 = alphaCoeff * u² / 2
            int256 term2 = (alphaCoeff * u2) / (2 * int256(ONE));

            int256 result = int256(ONE) + term1 + term2;
            return result > 0 ? uint256(result) : 0;
        }

        // General case: base^exp = exp(exp * ln(base))
        int256 lnBase = _ln(base);
        int256 product = (lnBase * int256(exponent)) / int256(ONE);
        return _exp(product);
    }

    /**
     * @notice Natural logarithm with improved range reduction to [1/√2, √2)
     * @dev Uses ln(x) = ln(x * 2^k / 2^k) = k*ln(2) + ln(x/2^(-k))
     * @param x Input value in 1e18 scale (must be > 0)
     * @return result = ln(x) in 1e18 scale (can be negative)
     */
    function _ln(uint256 x) internal pure returns (int256) {
        require(x > 0, "ln(0)");

        int256 result = 0;

        // Target range: [1/√2, √2) ≈ [0.707, 1.414)
        // This gives |u| < 0.414 for Taylor series, much better convergence
        uint256 SQRT2 = 1414213562373095048;  // √2 in 1e18
        uint256 INV_SQRT2 = 707106781186547524;  // 1/√2 in 1e18

        // Range reduction: scale x to [INV_SQRT2, SQRT2)
        while (x < INV_SQRT2) {
            x = x * 2;
            result -= int256(LN2);
        }
        while (x >= SQRT2) {
            x = x / 2;
            result += int256(LN2);
        }

        // Now x is in [0.707, 1.414), compute ln(x) using Taylor series around 1
        // ln(1+u) = u - u²/2 + u³/3 - u⁴/4 + ...
        // where u = x - 1, and |u| < 0.414
        int256 u = int256(x) - int256(ONE);

        // For better convergence, use: ln(x) = 2*arctanh((x-1)/(x+1))
        // But Taylor series should be fine for |u| < 0.414 with enough terms

        int256 term = u;
        int256 sum = term;
        int256 uPower = u;

        // Unroll 12 terms for accuracy
        uPower = uPower * u / int256(ONE);  // u²
        sum -= uPower / 2;

        uPower = uPower * u / int256(ONE);  // u³
        sum += uPower / 3;

        uPower = uPower * u / int256(ONE);  // u⁴
        sum -= uPower / 4;

        uPower = uPower * u / int256(ONE);  // u⁵
        sum += uPower / 5;

        uPower = uPower * u / int256(ONE);  // u⁶
        sum -= uPower / 6;

        uPower = uPower * u / int256(ONE);  // u⁷
        sum += uPower / 7;

        uPower = uPower * u / int256(ONE);  // u⁸
        sum -= uPower / 8;

        uPower = uPower * u / int256(ONE);  // u⁹
        sum += uPower / 9;

        uPower = uPower * u / int256(ONE);  // u¹⁰
        sum -= uPower / 10;

        uPower = uPower * u / int256(ONE);  // u¹¹
        sum += uPower / 11;

        uPower = uPower * u / int256(ONE);  // u¹²
        sum -= uPower / 12;

        return result + sum;
    }

    /**
     * @notice Exponential function with range reduction
     * @dev Uses exp(x) = exp(x mod ln2) * 2^(x/ln2)
     * @param x Input value in 1e18 scale (can be negative)
     * @return result = e^x in 1e18 scale
     */
    function _exp(int256 x) internal pure returns (uint256) {
        // Handle extreme cases
        if (x < -42 * int256(ONE)) return 0;  // Underflow
        if (x > 130 * int256(ONE)) return type(uint256).max;  // Overflow

        // Range reduction: exp(x) = 2^k * exp(r) where x = k*ln(2) + r
        // k = floor(x / ln(2))
        int256 k;
        if (x >= 0) {
            k = x / int256(LN2);
        } else {
            // For negative x, we need floor division (round toward -inf)
            k = (x - int256(LN2) + 1) / int256(LN2);
        }
        int256 r = x - k * int256(LN2);  // r is in (-ln2, ln2)

        // Compute exp(r) using Taylor series
        // exp(r) = 1 + r + r²/2! + r³/3! + r⁴/4! + ...
        int256 term = int256(ONE);
        int256 sum = term;

        // Unroll 12 terms for accuracy
        term = term * r / int256(ONE);
        sum += term;  // r

        term = term * r / int256(2 * ONE);
        sum += term;  // r²/2!

        term = term * r / int256(3 * ONE);
        sum += term;  // r³/3!

        term = term * r / int256(4 * ONE);
        sum += term;  // r⁴/4!

        term = term * r / int256(5 * ONE);
        sum += term;  // r⁵/5!

        term = term * r / int256(6 * ONE);
        sum += term;  // r⁶/6!

        term = term * r / int256(7 * ONE);
        sum += term;  // r⁷/7!

        term = term * r / int256(8 * ONE);
        sum += term;  // r⁸/8!

        term = term * r / int256(9 * ONE);
        sum += term;  // r⁹/9!

        term = term * r / int256(10 * ONE);
        sum += term;  // r¹⁰/10!

        term = term * r / int256(11 * ONE);
        sum += term;  // r¹¹/11!

        term = term * r / int256(12 * ONE);
        sum += term;  // r¹²/12!

        // Apply the 2^k multiplier
        if (sum <= 0) return 0;

        if (k >= 0) {
            if (k > 255) return type(uint256).max;  // Overflow protection
            return uint256(sum) << uint256(k);
        } else {
            if (-k > 255) return 0;  // Underflow protection
            return uint256(sum) >> uint256(-k);
        }
    }
}
