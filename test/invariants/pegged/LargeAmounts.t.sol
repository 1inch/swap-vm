// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title LargeAmounts
 * @notice Tests PeggedSwap with large swap amounts (significant % of pool)
 */
contract LargeAmounts is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        balanceA = 1000e18;
        balanceB = 1000e18;
        x0 = 1000e18;
        y0 = 1000e18;
        linearWidth = 0.8e27;

        // Large amounts (10-50% of pool)
        testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 300e18;
        testAmounts[2] = 500e18;

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 50e18;
        testAmountsExactOut[1] = 100e18;
        testAmountsExactOut[2] = 200e18;

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        symmetryTolerance = 1010;
        additivityTolerance = 2000;
    }
}
