// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title LargeAmounts
 * @notice Tests XYC + fees with large swap amounts relative to pool
 * @dev Edge case: testing high price impact scenarios with fees
 */
contract LargeAmounts is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard pool
        balanceA = 1000e18;
        balanceB = 1000e18;

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        flatFeeOutBps = 0.003e9;       // 0.3%
        progressiveFeeInBps = 0.05e9;  // 5%
        progressiveFeeOutBps = 0.05e9; // 5%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Large amounts relative to pool (10-30% of pool)
        // Note: additivity test does swap(3*amount), so max = pool/3 = 333e18
        testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;   // 10% of pool
        testAmounts[1] = 200e18;   // 20% of pool
        testAmounts[2] = 300e18;   // 30% of pool (900e18 total for additivity)

        // ExactOut amounts must be < balanceB / 3 for additivity
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 100e18;  // 10% of pool
        testAmountsExactOut[1] = 150e18;  // 15% of pool
        testAmountsExactOut[2] = 200e18;  // 20% of pool (600e18 total)

        // Allow 1-wei rounding for large amounts
        additivityTolerance = 1;
    }
}
