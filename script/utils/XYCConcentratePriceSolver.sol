// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ONE } from "../../src/instructions/XYCConcentrate.sol";

/// @title XYCConcentratePriceSolver
/// @notice Deploy-time helpers for deriving a missing price bound from
///   (bLt, bGt, sqrtPspot) and one known bound.
library XYCConcentratePriceSolver {
    error CannotDeriveFromZeroBalanceLt();
    error CannotDeriveFromZeroBalanceGt();
    error InvalidPriceBounds();

    /// @notice Given bLt, bGt, sqrtPspot, sqrtPmin → compute sqrtPmax
    ///   From bGt: L = bGt / (sqrtPspot - sqrtPmin)
    ///   From bLt: sqrtPmax = L * sqrtPspot / (L - bLt * sqrtPspot / ONE)
    function computeSqrtPriceMax(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPspot,
        uint256 sqrtPmin
    ) internal pure returns (uint256 sqrtPmax) {
        require(bLt > 0, CannotDeriveFromZeroBalanceLt());
        require(sqrtPspot > sqrtPmin, InvalidPriceBounds());

        uint256 L = Math.mulDiv(bGt, ONE, sqrtPspot - sqrtPmin);
        uint256 denom = L - Math.mulDiv(bLt, sqrtPspot, ONE);
        sqrtPmax = Math.mulDiv(L, sqrtPspot, denom);
    }

    /// @notice Given bLt, bGt, sqrtPspot, sqrtPmax → compute sqrtPmin
    ///   Uses bGt/bLt ratio to avoid L recovery (targetL cancels out):
    ///     sqrtPspot - sqrtPmin = ceil((bGt/bLt) * (invSqrtPspot - invSqrtPmax))
    function computeSqrtPriceMin(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPspot,
        uint256 sqrtPmax
    ) internal pure returns (uint256 sqrtPmin) {
        require(bLt > 0, CannotDeriveFromZeroBalanceLt());
        require(bGt > 0, CannotDeriveFromZeroBalanceGt());
        require(sqrtPmax > sqrtPspot, InvalidPriceBounds());

        uint256 invSqrtPspot = Math.mulDiv(ONE, ONE, sqrtPspot);
        uint256 invSqrtPmax = Math.mulDiv(ONE, ONE, sqrtPmax);
        sqrtPmin = sqrtPspot - Math.mulDiv(bGt, invSqrtPspot - invSqrtPmax, bLt, Math.Rounding.Ceil);
    }
}
