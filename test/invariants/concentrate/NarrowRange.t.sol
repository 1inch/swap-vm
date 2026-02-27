// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title NarrowRange
 * @notice Tests ConcentrateXYC with narrow price range (high concentration)
 * @dev Price range: 0.95 - 1.05 (±5%) - very high capital efficiency
 *      This creates maximum virtual liquidity, testing rounding at extreme concentration
 */
contract NarrowRange is ConcentrateXYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard balanced pool
        availableLiquidity = 1000e18;

        // NARROW concentration range (±5%)
        sqrtPriceMin = Math.sqrt(0.95e36);   // sqrt(0.95) in 1e18
        sqrtPriceMax = Math.sqrt(1.05e36);   // sqrt(1.05) in 1e18

        // Recompute balances - narrow range means more tokens in real balances
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

        // Tolerances - narrow range may amplify rounding
        symmetryTolerance = 0;
        additivityTolerance = 1;
    }
}
