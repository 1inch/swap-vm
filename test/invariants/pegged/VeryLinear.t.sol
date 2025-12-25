// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title VeryLinear
 * @notice Tests PeggedSwap with A = 0.95 (very linear, minimal curve)
 * @dev Optimal for stablecoins with very tight peg
 */
contract VeryLinear is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        balanceA = 1000e18;
        balanceB = 1000e18;
        x0 = 1000e18;
        y0 = 1000e18;
        linearWidth = 0.95e27;  // A = 0.95: very linear

        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // VeryLinear (A=0.95) has higher rounding errors
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
    }
}
