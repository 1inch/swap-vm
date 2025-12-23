// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title ImbalancedPoolLowFees
 * @notice Tests XYC + fees with extremely imbalanced pool (A >> B) and low fees
 * @dev Edge case: 10^14:1 ratio simulating SHIB/USDC-like pool with high price impact
 */
contract ImbalancedPoolLowFees is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Extremely imbalanced pool simulating SHIB/USDC (mixed decimals)
        // balanceA = 10^22 (10000 tokens with 18 decimals)
        // balanceB = 10^8 (100 tokens with 6 decimals)
        // Ratio: 10^22 / 10^8 = 10^14:1
        balanceA = 10000e18;
        balanceB = 100e6;

        // Very low fees
        flatFeeInBps = 0.0001e9;       // 0.01%
        flatFeeOutBps = 0.0001e9;      // 0.01%
        progressiveFeeInBps = 0.01e9;  // 1%
        progressiveFeeOutBps = 0.01e9; // 1%
        protocolFeeOutBps = 0.001e9;   // 0.1%

        // For extreme imbalanced pools (10^14:1 ratio with mixed decimals):
        // ExactIn testAmounts can be normal (1-10 tokens of A)
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;

        // ExactOut amounts must be < balanceB / 3 (for additivity test which uses amount * 3)
        // balanceB = 100e6, so max is ~33e6
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 5e6;    // 5% of balanceB
        testAmountsExactOut[1] = 10e6;   // 10% of balanceB
        testAmountsExactOut[2] = 20e6;   // 20% of balanceB (60e6 total for additivity)

        // Symmetry tolerance for extreme imbalanced pool:
        // Due to 6-decimal output token (like USDC), precision loss is high.
        // symmetryTolerance ≈ amountIn * (balanceA/balanceB) / 1e18
        //                   ≈ 10e18 * 10^14 / 1e18 = 10^15
        symmetryTolerance = 1e15;

        // Additivity tolerance: allow 1-wei rounding errors
        // (e.g., 29962 vs 29963 is acceptable for low-decimal output)
        additivityTolerance = 1;
    }
}
