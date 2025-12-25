// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title DustAmounts
 * @notice Tests PeggedSwap with dust amounts (wei-level)
 */
contract DustAmounts is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        balanceA = 1000e18;
        balanceB = 1000e18;
        x0 = 1000e18;
        y0 = 1000e18;
        linearWidth = 0.8e27;

        // Dust amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 1000;      // 1000 wei
        testAmounts[1] = 10000;     // 10000 wei
        testAmounts[2] = 1e12;      // 0.000001 tokens

        // Skip monotonicity for dust amounts (rounding > price impact)
        skipMonotonicity = true;
        skipSpotPrice = true;
        symmetryTolerance = 3100;
        additivityTolerance = 100;
    }
}
