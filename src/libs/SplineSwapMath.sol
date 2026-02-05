// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SplineSwapMath - Math library for SplineSwap
/// @notice Provides swap calculations using Uniform density with Spline price formula
/// @dev Uses 1e18 precision for normalized positions and prices
library SplineSwapMath {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10000;

    // ═══════════════════════════════════════════════════════════════════════════
    // DENSITY FUNCTION - Uniform: f(x) = x
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Evaluate density curve at normalized position x
    /// @param x Normalized position [0, 1e18]
    /// @return y The curve value f(x) = x
    function evaluateDensity(uint256 x) internal pure returns (uint256 y) {
        return x;
    }

    /// @notice Calculate integral of density curve from x0 to x1
    /// @dev F(x) = x²/2 → integral from x0 to x1 = (x1² - x0²) / 2
    /// @param x0 Start position [0, 1e18]
    /// @param x1 End position [0, 1e18]
    /// @return result The integral value scaled by 1e18
    function densityIntegral(uint256 x0, uint256 x1) internal pure returns (uint256 result) {
        uint256 F1 = x1 * x1 / (2 * ONE);
        uint256 F0 = x0 * x0 / (2 * ONE);
        return F1 > F0 ? F1 - F0 : F0 - F1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRICE FORMULA - Spline: P = P₀ · (1 ± r·f(x))
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculate price at given curve value
    /// @param basePrice Initial price P₀
    /// @param curveValue The f(x) value [0, 1e18]
    /// @param rangeBps Range in basis points (e.g., 2500 = 25%)
    /// @param isSell True for sell side (price increases), false for buy (price decreases)
    /// @return price The calculated price
    function calculatePrice(
        uint256 basePrice,
        uint256 curveValue,
        uint256 rangeBps,
        bool isSell
    ) internal pure returns (uint256 price) {
        // adjustment = r · f(x) in basis points
        uint256 adjustment = rangeBps * curveValue / ONE;
        if (isSell) {
            return basePrice * (BPS + adjustment) / BPS;
        } else {
            return basePrice * (BPS > adjustment ? BPS - adjustment : 0) / BPS;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AVERAGE PRICE CALCULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculate average price over a position range
    /// @param basePrice Initial price P₀
    /// @param rangeBps Range in basis points
    /// @param x0 Start normalized position [0, 1e18]
    /// @param x1 End normalized position [0, 1e18]
    /// @param isSell True for sell side
    /// @param spreadBps Spread to apply (ask or bid)
    /// @return avgPrice Average price with spread applied
    function getAveragePrice(
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
            curveValue = evaluateDensity(x0);
        } else {
            // Ensure x0 < x1
            if (x0 > x1) (x0, x1) = (x1, x0);
            uint256 deltaX = x1 - x0;

            // Calculate average curve value using integral
            uint256 integralValue = densityIntegral(x0, x1);
            curveValue = integralValue * ONE / deltaX;
        }

        // Calculate mid price at average curve value
        uint256 midPrice = calculatePrice(basePrice, curveValue, rangeBps, isSell);

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
