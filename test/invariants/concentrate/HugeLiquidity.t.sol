// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title HugeLiquidity
 * @notice Tests ConcentrateXYC + fees with very large liquidity pool
 * @dev Tests overflow protection and precision with large numbers
 */
contract HugeLiquidity is ConcentrateXYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Huge liquidity (large but safe for uint128)
        availableLiquidity = 2.5e25;  // 25 million tokens with 18 decimals

        // Standard concentration range
        sqrtPriceMin = Math.sqrt(0.8e36);
        sqrtPriceMax = Math.sqrt(1.25e36);

        // Recompute balances
        _computeInitialBalances();

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Large test amounts (but small relative to huge pool)
        testAmounts = new uint256[](5);
        testAmounts[0] = 1e21;
        testAmounts[1] = 10e21;
        testAmounts[2] = 100e21;
        testAmounts[3] = 1e23;
        testAmounts[4] = 10e23;

        symmetryTolerance = 0;  // 0 wei tolerance for huge numbers
        additivityTolerance = 1; // 1 wei tolerance (rounding from single-division bLt formula)
    }
}
