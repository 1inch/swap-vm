// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title ImbalancedPoolHighFees
 * @notice Tests XYC + fees with imbalanced pool (A >> B) and high fees
 * @dev Edge case: high price impact combined with high fees
 */
contract ImbalancedPoolHighFees is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Imbalanced pool: A is 100x more than B
        balanceA = 10000e18;
        balanceB = 100e18;

        // High fees
        flatFeeInBps = 0.01e9;        // 1%
        flatFeeOutBps = 0.01e9;       // 1%
        progressiveFeeInBps = 0.2e9;  // 20%
        progressiveFeeOutBps = 0.2e9; // 20%
        protocolFeeOutBps = 0.05e9;   // 5%

        // Smaller amounts due to imbalanced pool
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;

        // ExactOut amounts must be < balanceB / 3 for additivity test
        // balanceB = 100e18, so max ~33e18
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 5e18;
        testAmountsExactOut[1] = 10e18;
        testAmountsExactOut[2] = 20e18;

        // 100:1 ratio + high fees amplifies rounding to ~100 wei
        symmetryTolerance = 100;

        // Allow 1-wei rounding
        additivityTolerance = 1;

        // 100:1 ratio + high fees causes >5% price deviation (102/107.4 = 95%)
        roundingToleranceBps = 600;  // 6% = 600 bps
    }
}
