// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title TinyLiquidity
 * @notice Tests PeggedSwap with very small pool liquidity
 */
contract TinyLiquidity is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Small pool (not too tiny to avoid sqrt precision issues)
        balanceA = 1e18;   // 1 token
        balanceB = 1e18;
        x0 = 1e18;
        y0 = 1e18;
        linearWidth = 0.8e27;

        // Proportionally small amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 0.01e18;   // 1% of pool
        testAmounts[1] = 0.05e18;   // 5% of pool
        testAmounts[2] = 0.1e18;    // 10% of pool

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // Higher tolerance for tiny pools
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        // Very high rounding tolerance for tiny pools with progressive fees (35% = 3500 bps)
        roundingToleranceBps = 3500;
    }
}
