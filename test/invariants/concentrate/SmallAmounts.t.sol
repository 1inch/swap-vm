// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title SmallAmounts
 * @notice Tests ConcentrateXYC + fees with small swap amounts relative to pool
 * @dev Standard configuration with small trade sizes (0.01% - 0.1% of pool)
 */
contract SmallAmounts is ConcentrateXYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard balanced pool
        availableLiquidity = 1000e18;

        // Standard concentration range
        sqrtPriceMin = Math.sqrt(0.8e36);
        sqrtPriceMax = Math.sqrt(1.25e36);

        // Recompute balances
        _computeInitialBalances();

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Small test amounts (0.01% - 0.1% of pool)
        testAmounts = new uint256[](5);
        testAmounts[0] = 0.01e18;  // 0.01 tokens
        testAmounts[1] = 0.1e18;   // 0.1 tokens
        testAmounts[2] = 0.5e18;   // 0.5 tokens
        testAmounts[3] = 1e18;     // 1 token
        testAmounts[4] = 5e18;     // 5 tokens

        // Tolerances
        symmetryTolerance = 1;
        additivityTolerance = 1;
    }
}
