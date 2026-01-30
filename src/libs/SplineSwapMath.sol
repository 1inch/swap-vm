// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SplineSwapMath - Math library for SplineSwap with configurable curves
/// @notice Provides density strategies, price formulas, and swap calculations
/// @dev Uses 1e18 precision for normalized positions and prices
library SplineSwapMath {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10000;

    // ═══════════════════════════════════════════════════════════════════════════
    // DENSITY STRATEGY SELECTORS (ERC-165 style)
    // ═══════════════════════════════════════════════════════════════════════════

    bytes4 internal constant DENSITY_UNIFORM = bytes4(keccak256("Uniform"));
    bytes4 internal constant DENSITY_QUADRATIC = bytes4(keccak256("Quadratic"));
    bytes4 internal constant DENSITY_STABLE = bytes4(keccak256("Stable"));
    bytes4 internal constant DENSITY_EXP_DECAY = bytes4(keccak256("ExponentialDecay"));
    bytes4 internal constant DENSITY_EXP_GROWTH = bytes4(keccak256("ExponentialGrowth"));
    bytes4 internal constant DENSITY_CONCENTRATED = bytes4(keccak256("Concentrated"));
    bytes4 internal constant DENSITY_SQRT = bytes4(keccak256("SquareRoot"));
    bytes4 internal constant DENSITY_QUARTIC_DECAY = bytes4(keccak256("QuarticDecay"));
    bytes4 internal constant DENSITY_QUARTIC_GROWTH = bytes4(keccak256("QuarticGrowth"));
    bytes4 internal constant DENSITY_ANTI_CONCENTRATED = bytes4(keccak256("AntiConcentrated"));
    bytes4 internal constant DENSITY_PLATEAU = bytes4(keccak256("Plateau"));
    bytes4 internal constant DENSITY_SIGMOID = bytes4(keccak256("Sigmoid"));

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE FORMULA SELECTORS (ERC-165 style)
    // ═══════════════════════════════════════════════════════════════════════════

    bytes4 internal constant PRICE_SPLINE = bytes4(keccak256("Spline"));
    bytes4 internal constant PRICE_CONSTANT_PRODUCT = bytes4(keccak256("ConstantProduct"));
    bytes4 internal constant PRICE_EXPONENTIAL = bytes4(keccak256("Exponential"));
    bytes4 internal constant PRICE_STABLESWAP = bytes4(keccak256("StableSwap"));
    bytes4 internal constant PRICE_SQRT = bytes4(keccak256("Sqrt"));
    bytes4 internal constant PRICE_CUBIC = bytes4(keccak256("Cubic"));
    bytes4 internal constant PRICE_LOG = bytes4(keccak256("Log"));
    bytes4 internal constant PRICE_SIGMOID = bytes4(keccak256("Sigmoid"));
    bytes4 internal constant PRICE_HYPERBOLIC = bytes4(keccak256("Hyperbolic"));

    // ═══════════════════════════════════════════════════════════════════════════
    // SELECTOR ALIASES (for test compatibility)
    // ═══════════════════════════════════════════════════════════════════════════

    // Density selectors (test-friendly names)
    bytes4 internal constant UNIFORM_SELECTOR = DENSITY_UNIFORM;
    bytes4 internal constant QUADRATIC_SELECTOR = DENSITY_QUADRATIC;
    bytes4 internal constant STABLE_SELECTOR = DENSITY_STABLE;
    bytes4 internal constant EXP_DECAY_SELECTOR = DENSITY_EXP_DECAY;
    bytes4 internal constant EXP_GROWTH_SELECTOR = DENSITY_EXP_GROWTH;
    bytes4 internal constant CONCENTRATED_SELECTOR = DENSITY_CONCENTRATED;
    bytes4 internal constant SQRT_DENSITY_SELECTOR = DENSITY_SQRT;
    bytes4 internal constant QUARTIC_DECAY_SELECTOR = DENSITY_QUARTIC_DECAY;
    bytes4 internal constant QUARTIC_GROWTH_SELECTOR = DENSITY_QUARTIC_GROWTH;
    bytes4 internal constant ANTI_CONCENTRATED_SELECTOR = DENSITY_ANTI_CONCENTRATED;
    bytes4 internal constant PLATEAU_SELECTOR = DENSITY_PLATEAU;
    bytes4 internal constant SIGMOID_DENSITY_SELECTOR = DENSITY_SIGMOID;

    // Price formula selectors (test-friendly names)
    bytes4 internal constant SPLINE_PRICE_SELECTOR = PRICE_SPLINE;
    bytes4 internal constant CONSTANT_PRODUCT_SELECTOR = PRICE_CONSTANT_PRODUCT;
    bytes4 internal constant EXPONENTIAL_SELECTOR = PRICE_EXPONENTIAL;
    bytes4 internal constant STABLESWAP_SELECTOR = PRICE_STABLESWAP;
    bytes4 internal constant SQRT_PRICE_SELECTOR = PRICE_SQRT;
    bytes4 internal constant CUBIC_SELECTOR = PRICE_CUBIC;
    bytes4 internal constant LOG_SELECTOR = PRICE_LOG;
    bytes4 internal constant SIGMOID_PRICE_SELECTOR = PRICE_SIGMOID;
    bytes4 internal constant HYPERBOLIC_SELECTOR = PRICE_HYPERBOLIC;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error SplineSwapMathUnknownDensity(bytes4 selector);
    error SplineSwapMathUnknownPriceFormula(bytes4 selector);
    error SplineSwapMathInvalidInput();

    // ═══════════════════════════════════════════════════════════════════════════
    // DENSITY STRATEGIES - Evaluate f(x)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Evaluate density curve at normalized position x
    /// @param selector The density strategy selector
    /// @param x Normalized position [0, 1e18]
    /// @return y The curve value f(x) scaled by 1e18
    function evaluateDensity(bytes4 selector, uint256 x) internal pure returns (uint256 y) {
        if (selector == DENSITY_UNIFORM) return _densityUniform(x);
        if (selector == DENSITY_QUADRATIC) return _densityQuadratic(x);
        if (selector == DENSITY_STABLE) return _densityStable(x);
        if (selector == DENSITY_EXP_DECAY) return _densityExpDecay(x);
        if (selector == DENSITY_EXP_GROWTH) return _densityExpGrowth(x);
        if (selector == DENSITY_CONCENTRATED) return _densityConcentrated(x);
        if (selector == DENSITY_SQRT) return _densitySqrt(x);
        if (selector == DENSITY_QUARTIC_DECAY) return _densityQuarticDecay(x);
        if (selector == DENSITY_QUARTIC_GROWTH) return _densityQuarticGrowth(x);
        if (selector == DENSITY_ANTI_CONCENTRATED) return _densityAntiConcentrated(x);
        if (selector == DENSITY_PLATEAU) return _densityPlateau(x);
        if (selector == DENSITY_SIGMOID) return _densitySigmoid(x);
        revert SplineSwapMathUnknownDensity(selector);
    }

    /// @notice Calculate integral of density curve from x0 to x1
    /// @param selector The density strategy selector
    /// @param x0 Start position [0, 1e18]
    /// @param x1 End position [0, 1e18]
    /// @return result The integral value scaled by 1e18
    function densityIntegral(bytes4 selector, uint256 x0, uint256 x1) internal pure returns (uint256 result) {
        if (selector == DENSITY_UNIFORM) return _integralUniform(x0, x1);
        if (selector == DENSITY_QUADRATIC) return _integralQuadratic(x0, x1);
        if (selector == DENSITY_STABLE) return _integralStable(x0, x1);
        if (selector == DENSITY_EXP_DECAY) return _integralExpDecay(x0, x1);
        if (selector == DENSITY_EXP_GROWTH) return _integralExpGrowth(x0, x1);
        if (selector == DENSITY_CONCENTRATED) return _integralConcentrated(x0, x1);
        if (selector == DENSITY_SQRT) return _integralSqrt(x0, x1);
        if (selector == DENSITY_QUARTIC_DECAY) return _integralQuarticDecay(x0, x1);
        if (selector == DENSITY_QUARTIC_GROWTH) return _integralQuarticGrowth(x0, x1);
        if (selector == DENSITY_ANTI_CONCENTRATED) return _integralAntiConcentrated(x0, x1);
        if (selector == DENSITY_PLATEAU) return _integralPlateau(x0, x1);
        if (selector == DENSITY_SIGMOID) return _integralSigmoid(x0, x1);
        revert SplineSwapMathUnknownDensity(selector);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DENSITY IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev f(x) = x (Uniform)
    function _densityUniform(uint256 x) private pure returns (uint256) {
        return x;
    }

    /// @dev F(x) = x²/2 → integral from x0 to x1 = (x1² - x0²) / 2
    function _integralUniform(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 F1 = x1 * x1 / (2 * ONE);
        uint256 F0 = x0 * x0 / (2 * ONE);
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = x(2-x) (Quadratic)
    function _densityQuadratic(uint256 x) private pure returns (uint256) {
        uint256 twoMinusX = 2 * ONE - x;
        return x * twoMinusX / ONE;
    }

    /// @dev F(x) = x² - x³/3 → integral
    function _integralQuadratic(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 F1 = x1 * x1 / ONE - x1 * x1 / ONE * x1 / (3 * ONE);
        uint256 F0 = x0 * x0 / ONE - x0 * x0 / ONE * x0 / (3 * ONE);
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = 1 - (1-x)² (Stable)
    function _densityStable(uint256 x) private pure returns (uint256) {
        uint256 oneMinusX = ONE - x;
        uint256 squared = oneMinusX * oneMinusX / ONE;
        return ONE - squared;
    }

    /// @dev F(x) = x - (1-x)³/3 + 1/3 → integral
    function _integralStable(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 oneMinusX1 = ONE - x1;
        uint256 oneMinusX0 = ONE - x0;
        uint256 cubed1 = oneMinusX1 * oneMinusX1 / ONE * oneMinusX1 / ONE;
        uint256 cubed0 = oneMinusX0 * oneMinusX0 / ONE * oneMinusX0 / ONE;
        // F(x) = x + (1-x)³/3
        uint256 F1 = x1 + cubed1 / 3;
        uint256 F0 = x0 + cubed0 / 3;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = x³ (ExponentialDecay)
    function _densityExpDecay(uint256 x) private pure returns (uint256) {
        return x * x / ONE * x / ONE;
    }

    /// @dev F(x) = x⁴/4 → integral
    function _integralExpDecay(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 x1_2 = x1 * x1 / ONE;
        uint256 x1_4 = x1_2 * x1_2 / ONE;
        uint256 x0_2 = x0 * x0 / ONE;
        uint256 x0_4 = x0_2 * x0_2 / ONE;
        uint256 F1 = x1_4 / 4;
        uint256 F0 = x0_4 / 4;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = 1 - (1-x)³ (ExponentialGrowth)
    function _densityExpGrowth(uint256 x) private pure returns (uint256) {
        uint256 oneMinusX = ONE - x;
        uint256 cubed = oneMinusX * oneMinusX / ONE * oneMinusX / ONE;
        return ONE - cubed;
    }

    /// @dev F(x) = x + (1-x)⁴/4 - 1/4 → integral
    function _integralExpGrowth(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 oneMinusX1 = ONE - x1;
        uint256 oneMinusX0 = ONE - x0;
        uint256 pow4_1 = oneMinusX1 * oneMinusX1 / ONE;
        pow4_1 = pow4_1 * pow4_1 / ONE;
        uint256 pow4_0 = oneMinusX0 * oneMinusX0 / ONE;
        pow4_0 = pow4_0 * pow4_0 / ONE;
        // F(x) = x + (1-x)⁴/4
        uint256 F1 = x1 + pow4_1 / 4;
        uint256 F0 = x0 + pow4_0 / 4;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = 3x² - 2x³ (Concentrated/Smoothstep)
    function _densityConcentrated(uint256 x) private pure returns (uint256) {
        uint256 x2 = x * x / ONE;
        uint256 x3 = x2 * x / ONE;
        return 3 * x2 - 2 * x3;
    }

    /// @dev F(x) = x³ - x⁴/2 → integral
    function _integralConcentrated(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 x1_2 = x1 * x1 / ONE;
        uint256 x1_3 = x1_2 * x1 / ONE;
        uint256 x1_4 = x1_2 * x1_2 / ONE;
        uint256 x0_2 = x0 * x0 / ONE;
        uint256 x0_3 = x0_2 * x0 / ONE;
        uint256 x0_4 = x0_2 * x0_2 / ONE;
        uint256 F1 = x1_3 - x1_4 / 2;
        uint256 F0 = x0_3 - x0_4 / 2;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = √x (SquareRoot)
    function _densitySqrt(uint256 x) private pure returns (uint256) {
        return Math.sqrt(x * ONE);
    }

    /// @dev F(x) = (2/3)x^(3/2) → integral
    function _integralSqrt(uint256 x0, uint256 x1) private pure returns (uint256) {
        // F(x) = (2/3) * x * sqrt(x) = (2/3) * x^(3/2)
        uint256 sqrt1 = Math.sqrt(x1 * ONE);
        uint256 sqrt0 = Math.sqrt(x0 * ONE);
        uint256 F1 = 2 * x1 * sqrt1 / (3 * ONE);
        uint256 F0 = 2 * x0 * sqrt0 / (3 * ONE);
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = x⁴ (QuarticDecay)
    function _densityQuarticDecay(uint256 x) private pure returns (uint256) {
        uint256 x2 = x * x / ONE;
        return x2 * x2 / ONE;
    }

    /// @dev F(x) = x⁵/5 → integral
    function _integralQuarticDecay(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 x1_2 = x1 * x1 / ONE;
        uint256 x1_4 = x1_2 * x1_2 / ONE;
        uint256 x1_5 = x1_4 * x1 / ONE;
        uint256 x0_2 = x0 * x0 / ONE;
        uint256 x0_4 = x0_2 * x0_2 / ONE;
        uint256 x0_5 = x0_4 * x0 / ONE;
        uint256 F1 = x1_5 / 5;
        uint256 F0 = x0_5 / 5;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = 1 - (1-x)⁴ (QuarticGrowth)
    function _densityQuarticGrowth(uint256 x) private pure returns (uint256) {
        uint256 oneMinusX = ONE - x;
        uint256 pow2 = oneMinusX * oneMinusX / ONE;
        uint256 pow4 = pow2 * pow2 / ONE;
        return ONE - pow4;
    }

    /// @dev F(x) = x + (1-x)⁵/5 - 1/5 → integral
    function _integralQuarticGrowth(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 oneMinusX1 = ONE - x1;
        uint256 oneMinusX0 = ONE - x0;
        uint256 pow2_1 = oneMinusX1 * oneMinusX1 / ONE;
        uint256 pow4_1 = pow2_1 * pow2_1 / ONE;
        uint256 pow5_1 = pow4_1 * oneMinusX1 / ONE;
        uint256 pow2_0 = oneMinusX0 * oneMinusX0 / ONE;
        uint256 pow4_0 = pow2_0 * pow2_0 / ONE;
        uint256 pow5_0 = pow4_0 * oneMinusX0 / ONE;
        // F(x) = x + (1-x)⁵/5
        uint256 F1 = x1 + pow5_1 / 5;
        uint256 F0 = x0 + pow5_0 / 5;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    /// @dev f(x) = 6x⁵ - 15x⁴ + 10x³ (AntiConcentrated/Smootherstep)
    /// Note: This is smootherstep, which equals x at boundaries: f(0)=0, f(1)=1
    function _densityAntiConcentrated(uint256 x) private pure returns (uint256) {
        uint256 x2 = x * x / ONE;
        uint256 x3 = x2 * x / ONE;
        uint256 x4 = x2 * x2 / ONE;
        uint256 x5 = x4 * x / ONE;
        // Reorder to avoid underflow: 10x³ + 6x⁵ - 15x⁴ = x³(10 + 6x² - 15x)
        // Alternative safe form: 6x⁵ + 10x³ >= 15x⁴ for x in [0,1]
        // Actually, use signed arithmetic to be safe
        int256 result = int256(6 * x5) - int256(15 * x4) + int256(10 * x3);
        return result > 0 ? uint256(result) : 0;
    }

    /// @dev F(x) = x⁶ - 3x⁵ + 5x⁴/2 → integral
    function _integralAntiConcentrated(uint256 x0, uint256 x1) private pure returns (uint256) {
        // Use signed arithmetic to avoid underflow
        int256 F1 = _antiConcentratedAntiderivative(x1);
        int256 F0 = _antiConcentratedAntiderivative(x0);
        int256 diff = F1 - F0;
        return diff > 0 ? uint256(diff) : uint256(-diff);
    }
    
    /// @dev Helper for anti-concentrated antiderivative
    function _antiConcentratedAntiderivative(uint256 x) private pure returns (int256) {
        uint256 x2 = x * x / ONE;
        uint256 x4 = x2 * x2 / ONE;
        uint256 x5 = x4 * x / ONE;
        uint256 x6 = x4 * x2 / ONE;
        // F(x) = x⁶ - 3x⁵ + 5x⁴/2
        return int256(x6) - int256(3 * x5) + int256(5 * x4 / 2);
    }

    /// @dev f(x) = x + 4x²(1-x)²(0.5-x) (Plateau)
    function _densityPlateau(uint256 x) private pure returns (uint256) {
        uint256 x2 = x * x / ONE;
        uint256 oneMinusX = ONE - x;
        uint256 oneMinusX2 = oneMinusX * oneMinusX / ONE;
        int256 halfMinusX = int256(ONE / 2) - int256(x);
        // 4x²(1-x)²(0.5-x)
        int256 term = int256(4 * x2 * oneMinusX2 / ONE) * halfMinusX / int256(ONE);
        // x + term
        if (term >= 0) {
            return x + uint256(term);
        } else {
            return x > uint256(-term) ? x - uint256(-term) : 0;
        }
    }

    /// @dev Approximate integral for Plateau using trapezoidal rule
    function _integralPlateau(uint256 x0, uint256 x1) private pure returns (uint256) {
        // Use trapezoidal approximation: (f(x0) + f(x1)) * (x1 - x0) / 2
        uint256 f0 = _densityPlateau(x0);
        uint256 f1 = _densityPlateau(x1);
        return (f0 + f1) * (x1 > x0 ? x1 - x0 : x0 - x1) / (2 * ONE);
    }

    /// @dev f(x) = 35x⁴ - 84x⁵ + 70x⁶ - 20x⁷ (Sigmoid/Septic smoothstep)
    function _densitySigmoid(uint256 x) private pure returns (uint256) {
        uint256 x2 = x * x / ONE;
        uint256 x4 = x2 * x2 / ONE;
        uint256 x5 = x4 * x / ONE;
        uint256 x6 = x4 * x2 / ONE;
        uint256 x7 = x6 * x / ONE;
        return 35 * x4 - 84 * x5 + 70 * x6 - 20 * x7;
    }

    /// @dev F(x) = 7x⁵ - 14x⁶ + 10x⁷ - 5x⁸/2 → integral
    function _integralSigmoid(uint256 x0, uint256 x1) private pure returns (uint256) {
        uint256 x1_2 = x1 * x1 / ONE;
        uint256 x1_4 = x1_2 * x1_2 / ONE;
        uint256 x1_5 = x1_4 * x1 / ONE;
        uint256 x1_6 = x1_4 * x1_2 / ONE;
        uint256 x1_7 = x1_6 * x1 / ONE;
        uint256 x1_8 = x1_4 * x1_4 / ONE;
        uint256 x0_2 = x0 * x0 / ONE;
        uint256 x0_4 = x0_2 * x0_2 / ONE;
        uint256 x0_5 = x0_4 * x0 / ONE;
        uint256 x0_6 = x0_4 * x0_2 / ONE;
        uint256 x0_7 = x0_6 * x0 / ONE;
        uint256 x0_8 = x0_4 * x0_4 / ONE;
        // F(x) = 7x⁵ - 14x⁶ + 10x⁷ - 5x⁸/2
        uint256 F1 = 7 * x1_5 - 14 * x1_6 + 10 * x1_7 - 5 * x1_8 / 2;
        uint256 F0 = 7 * x0_5 - 14 * x0_6 + 10 * x0_7 - 5 * x0_8 / 2;
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE FORMULAS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculate price at given curve value using the specified formula
    /// @param selector The price formula selector
    /// @param basePrice Initial price P₀
    /// @param curveValue The f(x) value from density strategy [0, 1e18]
    /// @param rangeBps Range in basis points (e.g., 2500 = 25%)
    /// @param isSell True for sell side (price increases), false for buy (price decreases)
    /// @return price The calculated price
    function calculatePrice(
        bytes4 selector,
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) internal pure returns (uint256 price) {
        if (selector == PRICE_SPLINE) return _priceSpline(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_CONSTANT_PRODUCT) return _priceConstantProduct(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_EXPONENTIAL) return _priceExponential(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_STABLESWAP) return _priceStableSwap(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_SQRT) return _priceSqrt(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_CUBIC) return _priceCubic(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_LOG) return _priceLog(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_SIGMOID) return _priceSigmoid(basePrice, curveValue, rangeBps, isSell);
        if (selector == PRICE_HYPERBOLIC) return _priceHyperbolic(basePrice, curveValue, rangeBps, isSell);
        revert SplineSwapMathUnknownPriceFormula(selector);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE FORMULA IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev P = P₀ · (1 ± r·f(x)) (Spline/Default)
    function _priceSpline(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        // adjustment = r · f(x) in basis points
        uint256 adjustment = rangeBps * curveValue / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·f(x))² (ConstantProduct)
    function _priceConstantProduct(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        uint256 adjustment = rangeBps * curveValue / ONE;
        uint256 factor;
        if (isSell) {
            factor = BPS + adjustment;
        } else {
            factor = BPS > adjustment ? BPS - adjustment : 0;
        }
        return basePrice * factor / BPS * factor / BPS;
    }

    /// @dev P = P₀ · e^(±r·f(x)) (Exponential) - using Taylor approximation
    function _priceExponential(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        // e^x ≈ 1 + x + x²/2 + x³/6 for small x
        // x = r · f(x) / BPS
        uint256 x = rangeBps * curveValue / BPS;
        uint256 x2 = x * x / ONE;
        uint256 x3 = x2 * x / ONE;
        
        // e^x ≈ 1 + x + x²/2 + x³/6
        uint256 expFactor = ONE + x + x2 / 2 + x3 / 6;
        
        if (isSell) {
            return basePrice * expFactor / ONE;
        } else {
            // e^(-x) ≈ 1 / e^x ≈ 2 - e^x for small x (better: use 1/(1+x+x²/2))
            uint256 invFactor = ONE * ONE / expFactor;
            return basePrice * invFactor / ONE;
        }
    }

    /// @dev P = P₀ · (1 ± r·f(x)⁴) (StableSwap)
    function _priceStableSwap(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        uint256 cv2 = curveValue * curveValue / ONE;
        uint256 cv4 = cv2 * cv2 / ONE;
        uint256 adjustment = rangeBps * cv4 / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·√f(x)) (Sqrt)
    function _priceSqrt(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        uint256 sqrtCv = Math.sqrt(curveValue * ONE);
        uint256 adjustment = rangeBps * sqrtCv / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·f(x)³) (Cubic)
    function _priceCubic(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        uint256 cv3 = curveValue * curveValue / ONE * curveValue / ONE;
        uint256 adjustment = rangeBps * cv3 / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·ln(1+f(x))/ln(2)) (Log)
    /// Using approximation: ln(1+x) ≈ x - x²/2 + x³/3 for x ∈ [0,1]
    function _priceLog(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        // ln(1+x) / ln(2) ≈ (x - x²/2 + x³/3) / 0.693
        // For simplicity, use approximation that ln(1+x)/ln(2) ≈ 1.44 * (x - x²/2)
        uint256 cv2 = curveValue * curveValue / ONE;
        uint256 logTerm = curveValue - cv2 / 2;
        // Multiply by ~1.44 (use 144/100)
        uint256 normalizedLog = logTerm * 144 / 100;
        uint256 adjustment = rangeBps * normalizedLog / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·(3f(x)² - 2f(x)³)) (Sigmoid/Smoothstep)
    function _priceSigmoid(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        uint256 cv2 = curveValue * curveValue / ONE;
        uint256 cv3 = cv2 * curveValue / ONE;
        uint256 smoothstep = 3 * cv2 - 2 * cv3;
        uint256 adjustment = rangeBps * smoothstep / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    /// @dev P = P₀ · (1 ± r·f(x)/(1 - 0.9·f(x))) (Hyperbolic)
    function _priceHyperbolic(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) private pure returns (uint256) {
        // denominator = 1 - 0.9 * f(x)
        uint256 denom = ONE - 9 * curveValue / 10;
        if (denom == 0) denom = 1; // Prevent division by zero
        uint256 hyperTerm = curveValue * ONE / denom;
        uint256 adjustment = rangeBps * hyperTerm / ONE;
        // Cap adjustment to prevent extreme values
        if (adjustment > 2 * BPS) adjustment = 2 * BPS;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AVERAGE PRICE CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculate average price over a position range using trapezoidal approximation
    /// @param densitySelector Density strategy selector
    /// @param priceSelector Price formula selector
    /// @param basePrice Initial price P₀
    /// @param rangeBps Range in basis points
    /// @param x0 Start normalized position [0, 1e18]
    /// @param x1 End normalized position [0, 1e18]
    /// @param isSell True for sell side
    /// @param spreadBps Spread to apply (ask or bid)
    /// @return avgPrice Average price with spread applied
    function getAveragePrice(
        bytes4 densitySelector,
        bytes4 priceSelector,
        uint256 basePrice,
        uint256 rangeBps,
        uint256 x0,
        uint256 x1,
        bool isSell,
        uint256 spreadBps
    ) internal pure returns (uint256 avgPrice) {
        uint256 curveValue;
        
        if (x0 == x1) {
            // Point price
            curveValue = evaluateDensity(densitySelector, x0);
        } else {
            // Ensure x0 < x1
            if (x0 > x1) (x0, x1) = (x1, x0);
            uint256 deltaX = x1 - x0;

            // Calculate average curve value using integral
            uint256 integralValue = densityIntegral(densitySelector, x0, x1);
            curveValue = integralValue * ONE / deltaX;
        }

        // Calculate mid price at average curve value
        uint256 midPrice = calculatePrice(priceSelector, basePrice, curveValue, rangeBps, isSell);

        // Apply spread
        avgPrice = _applySpread(midPrice, spreadBps, isSell);
    }

    /// @dev Apply bid/ask spread to price
    function _applySpread(uint256 price, uint256 spreadBps, bool isAsk) private pure returns (uint256) {
        if (isAsk) {
            // Taker pays more (round up)
            return Math.ceilDiv(price * (BPS + spreadBps), BPS);
        } else {
            // Taker receives less (round down)
            return price * (BPS - spreadBps) / BPS;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Ceiling division
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
