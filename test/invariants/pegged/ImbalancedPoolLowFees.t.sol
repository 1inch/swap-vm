// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title ImbalancedPoolLowFees
 * @notice Tests PeggedSwap with imbalanced pool and low fees
 */
contract ImbalancedPoolLowFees is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Imbalanced pool: 10:1 ratio
        balanceA = 10000e18;
        balanceB = 1000e18;
        x0 = 10000e18;
        y0 = 1000e18;
        linearWidth = 0.5e27;

        // Low fees
        flatFeeInBps = 0.001e9;   // 0.1%
        flatFeeOutBps = 0.001e9;  // 0.1%

        testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 500e18;
        testAmounts[2] = 1000e18;

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 10e18;
        testAmountsExactOut[1] = 50e18;
        testAmountsExactOut[2] = 100e18;

        symmetryTolerance = 100;
    }
}
