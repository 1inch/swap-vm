// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";


/**
 * @title DustAmounts
 * @notice Tests XYC + fees with dust amounts (wei-level trades)
 * @dev Edge case: demonstrates invariant limitations for dust amounts
 *
 * ## What breaks for dust amounts:
 *
 * 1. **Monotonicity**: For very small trades (1-1000 wei), rounding error
 *    dominates price impact. Larger trades can get BETTER rates because
 *    relative rounding error is smaller.
 *    Example: 1000 wei → 999 out (rate 0.999), 10000 wei → 9999 out (rate 0.9999)
 *
 * 2. **Spot Price Check**: Small trades (<0.1% of pool) get better rates than
 *    spot price calculated from 1-token trade due to minimal price impact.
 *    This is correct AMM behavior, not a bug.
 *
 * 3. **Additivity**: May appear violated due to compounding rounding errors
 *    when splitting dust amounts.
 *
 * ## Why this matters (or doesn't):
 * - Dust trades are NOT economically exploitable (gas >> profit)
 * - Invariants are designed to catch economic attacks, not wei-level precision
 * - Production systems should have minimum trade amounts anyway
 */
contract DustAmounts is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard balanced pool
        balanceA = 1000e18;
        balanceB = 1000e18;

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        flatFeeOutBps = 0.003e9;       // 0.3%
        progressiveFeeInBps = 0.05e9;  // 5%
        progressiveFeeOutBps = 0.05e9; // 5%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Test absolute minimum for exactIn (1-2 wei gives output=0 for progressive fees)
        testAmounts = new uint256[](9);
        testAmounts[0] = 3;       // 3 wei - minimum for progressive fees
        testAmounts[1] = 5;       // 5 wei
        testAmounts[2] = 10;      // 10 wei
        testAmounts[3] = 20;      // 20 wei
        testAmounts[4] = 50;      // 50 wei
        testAmounts[5] = 100;     // 100 wei
        testAmounts[6] = 1000;    // 1000 wei
        testAmounts[7] = 10000;   // 10000 wei
        testAmounts[8] = 100000;  // 100000 wei

        // ExactOut: we request specific output, so 1-10 wei works
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;       // 1 wei
        testAmountsExactOut[1] = 10;      // 10 wei
        testAmountsExactOut[2] = 100;     // 100 wei
        testAmountsExactOut[3] = 1000;    // 1000 wei
        testAmountsExactOut[4] = 10000;   // 10000 wei
        testAmountsExactOut[5] = 100000;  // 100000 wei

        // Minimal tolerances that still pass (documents actual deviation)
        symmetryTolerance = 1;      // 1 wei
        additivityTolerance = 0;    // 0 wei

        // Monotonicity: 81% for progressive fees (3 wei→0.33, 5 wei→0.6, deviation=80%+rounding)
        monotonicityToleranceBps = 8100;  // 81% = 8100 bps

        // Rounding: 1% deviation from spot price (due to minimal price impact)
        roundingToleranceBps = 100;  // 1% = 100 bps
    }
}
