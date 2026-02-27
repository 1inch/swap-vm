// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title DustAmounts
 * @notice Tests ConcentrateXYC + fees with dust amounts (wei-level trades)
 * @dev Edge case: demonstrates invariant limitations for dust amounts
 *
 * ## What breaks for dust amounts:
 *
 * 1. **Monotonicity**: For very small trades (1-1000 wei), rounding error
 *    dominates price impact. Larger trades can get BETTER rates.
 *
 * 2. **Spot Price Check**: Small trades (<0.1% of pool) get better rates than
 *    spot price calculated from 1-token trade due to minimal price impact.
 *
 * 3. **Additivity**: May appear violated due to compounding rounding errors
 *    and L recalculation between swaps.
 *
 * ## Why this matters (or doesn't):
 * - Dust trades are NOT economically exploitable (gas >> profit)
 * - Invariants are designed to catch economic attacks, not wei-level precision
 */
contract DustAmounts is ConcentrateXYCFeesInvariants {
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

        // Test absolute minimum amounts
        testAmounts = new uint256[](10);
        testAmounts[0] = 1;       // 1 wei
        testAmounts[1] = 3;       // 3 wei
        testAmounts[2] = 5;       // 5 wei
        testAmounts[3] = 10;      // 10 wei
        testAmounts[4] = 20;      // 20 wei
        testAmounts[5] = 50;      // 50 wei
        testAmounts[6] = 100;     // 100 wei
        testAmounts[7] = 1000;    // 1000 wei
        testAmounts[8] = 10000;   // 10000 wei
        testAmounts[9] = 100000;  // 100000 wei

        // ExactOut: we request specific output
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;       // 1 wei
        testAmountsExactOut[1] = 10;      // 10 wei
        testAmountsExactOut[2] = 100;     // 100 wei
        testAmountsExactOut[3] = 1000;    // 1000 wei
        testAmountsExactOut[4] = 10000;   // 10000 wei
        testAmountsExactOut[5] = 100000;  // 100000 wei

        // Minimal tolerances
        symmetryTolerance = 1;      // 1 wei
        additivityTolerance = 1;    // 1 wei (concentrate needs this for L recalculation)

        // Monotonicity: dust amounts violate due to rounding
        monotonicityToleranceBps = 1;

        // Rounding: 1% deviation from spot price
        roundingToleranceBps = 100;  // 1%
    }
}
