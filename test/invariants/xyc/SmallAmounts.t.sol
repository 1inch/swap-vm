// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title SmallAmounts
 * @notice Tests XYC + fees with very small swap amounts relative to pool
 * @dev Edge case: testing fee rounding and precision with small trades
 */
contract SmallAmounts is XYCFeesInvariants {
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

        // Very small amounts relative to pool (< 0.1%)
        testAmounts = new uint256[](4);
        testAmounts[0] = 1e12;     // 0.000001 tokens
        testAmounts[1] = 1e14;     // 0.0001 tokens
        testAmounts[2] = 1e15;     // 0.001 tokens
        testAmounts[3] = 1e16;     // 0.01 tokens

        // Allow 1-wei rounding in additivity for small amounts
        additivityTolerance = 1;
    }
}
