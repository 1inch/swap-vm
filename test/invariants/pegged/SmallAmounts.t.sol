// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title SmallAmounts
 * @notice Tests PeggedSwap with small swap amounts
 */
contract SmallAmounts is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        balanceA = 1000e18;
        balanceB = 1000e18;
        x0 = 1000e18;
        y0 = 1000e18;
        linearWidth = 0.8e27;

        // Small amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 0.01e18;
        testAmounts[1] = 0.1e18;
        testAmounts[2] = 1e18;

        // Low fees
        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        symmetryTolerance = 1010;
        additivityTolerance = 2000;
    }
}
