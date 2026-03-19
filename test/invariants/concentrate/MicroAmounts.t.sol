// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title MicroAmounts
 * @notice Tests ConcentrateXYC + fees with micro amounts (2000 wei - 1B wei)
 * @dev Tests small but economically realistic trade sizes AFTER dust threshold
 *
 * ## Range Coverage:
 * - 2000 wei to 1 billion wei
 * - Tests amounts AFTER dust rounding effects fade away
 * - Normal invariants apply (strict tolerances)
 */
contract MicroAmounts is ConcentrateXYCFeesInvariants {
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

        // Test micro amounts (2000 wei to 1 billion wei)
        // Start at 2000 to avoid dust threshold (≤1000 wei)
        testAmounts = new uint256[](8);
        testAmounts[0] = 2000;       // 2000 wei
        testAmounts[1] = 5000;       // 5000 wei
        testAmounts[2] = 10000;      // 10000 wei
        testAmounts[3] = 100000;     // 100000 wei
        testAmounts[4] = 1000000;    // 1000000 wei
        testAmounts[5] = 10000000;   // 10000000 wei
        testAmounts[6] = 100000000;  // 100000000 wei
        testAmounts[7] = 1000000000; // 1000000000 wei

        // ExactOut: we request specific output
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;       // 1 wei
        testAmountsExactOut[1] = 10;      // 10 wei
        testAmountsExactOut[2] = 100;     // 100 wei
        testAmountsExactOut[3] = 1000;    // 1000 wei
        testAmountsExactOut[4] = 10000;   // 10000 wei
        testAmountsExactOut[5] = 100000;  // 100000 wei

        // Minimal tolerances
        symmetryTolerance = 2;      // 2 wei
        additivityTolerance = 1;    // 1 wei (concentrate needs this for L recalculation)

        // Monotonicity: dust amounts violate due to rounding
        monotonicityToleranceBps = 5;

        // Rounding: 1% deviation from spot price
        roundingToleranceBps = 100;  // 1%
    }
}
