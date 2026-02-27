// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title LargeAmounts
 * @notice Tests ConcentrateXYC + fees with large swap amounts (10-50% of pool)
 * @dev Tests high price impact scenarios where concentration boundaries matter
 */
contract LargeAmounts is ConcentrateXYCFeesInvariants {
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

        // Large test amounts (5-20% of available liquidity - safe range)
        testAmounts = new uint256[](5);
        testAmounts[0] = 50e18;
        testAmounts[1] = 100e18;
        testAmounts[2] = 150e18;
        testAmounts[3] = 200e18;
        testAmounts[4] = 250e18;

        // For exactOut, use smaller amounts (can't request more than balance)
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 30e18;
        testAmountsExactOut[1] = 50e18;
        testAmountsExactOut[2] = 100e18;

        // Tolerances
        symmetryTolerance = 0;
        additivityTolerance = 1;
    }
}
