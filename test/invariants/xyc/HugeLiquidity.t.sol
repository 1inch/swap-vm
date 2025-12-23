// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title HugeLiquidity
 * @notice Tests XYC + fees with very large pool balances
 * @dev Edge case: overflow protection with large numbers
 */
contract HugeLiquidity is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Very large liquidity (1 million tokens each)
        balanceA = 1e24;   // 1,000,000 tokens
        balanceB = 1e24;

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        flatFeeOutBps = 0.003e9;       // 0.3%
        progressiveFeeInBps = 0.05e9;  // 5%
        progressiveFeeOutBps = 0.05e9; // 5%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Large amounts matching huge liquidity
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e21;   // 1,000 tokens
        testAmounts[1] = 1e22;   // 10,000 tokens
        testAmounts[2] = 1e23;   // 100,000 tokens

        // Allow 1-wei rounding in additivity for large numbers
        additivityTolerance = 1;
    }
}
