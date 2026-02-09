// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

/**
 * @title CubeRoot
 * @notice Wrapper library for computing cube root (3rd root)
 * @dev Uses Solady's highly optimized FixedPointMathLib.cbrt()
 */
library CubeRoot {
    function cbrt(uint256 x) internal pure returns (uint256) {
        return FixedPointMathLib.cbrt(x);
    }
}
