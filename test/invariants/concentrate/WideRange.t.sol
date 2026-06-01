// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title WideRange
 * @notice Tests ConcentrateXYC with wide price range (low concentration)
 * @dev Price range: 0.5 - 2.0 (±50-100%) - approaches full-range behavior
 *      This creates minimal virtual liquidity, closer to standard XYC
 */
contract WideRange is ConcentrateXYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard balanced pool
        availableLiquidity = 1000e18;

        // WIDE concentration range (±50-100%)
        sqrtPriceMin = Math.sqrt(0.5e36);    // sqrt(0.5) in 1e18
        sqrtPriceMax = Math.sqrt(2.0e36);    // sqrt(2.0) in 1e18

        // Recompute balances - wide range means less tokens in real balances
        _computeInitialBalances();

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Test amounts
        testAmounts = new uint256[](5);
        testAmounts[0] = 1e18;     // 1 token
        testAmounts[1] = 10e18;    // 10 tokens
        testAmounts[2] = 50e18;    // 50 tokens
        testAmounts[3] = 100e18;   // 100 tokens
        testAmounts[4] = 200e18;   // 200 tokens

        // Tolerances
        symmetryTolerance = 0;
        additivityTolerance = 1;
    }
}
