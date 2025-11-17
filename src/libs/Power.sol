// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

library Power {
    /// @notice Calculates base^exponent with given precision
    /// @param base The base value (scaled by precision)
    /// @param exponent The exponent (unscaled)
    /// @param precision The precision scale (e.g., 1e18)
    /// @return result The result of base^exponent (scaled by precision)
    function pow(uint256 base, uint256 exponent, uint256 precision) internal pure returns (uint256 result) {
        result = precision;

        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = (result * base) / precision;
            }
            base = (base * base) / precision;
            exponent >>= 1;
        }
    }
}
