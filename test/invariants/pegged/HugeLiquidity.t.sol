// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";

/**
 * @title HugeLiquidity
 * @notice Tests PeggedSwap with very large pool liquidity
 */
contract HugeLiquidity is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Very large pool (billions)
        balanceA = 1e27;   // 1 billion tokens
        balanceB = 1e27;
        x0 = 1e27;
        y0 = 1e27;
        linearWidth = 0.8e27;

        // Large swap amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e24;   // 1 million tokens
        testAmounts[1] = 1e25;   // 10 million tokens
        testAmounts[2] = 1e26;   // 100 million tokens

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // Huge liquidity has proportionally larger absolute errors
        symmetryTolerance = 1e9;  // 1 gwei tolerance for billion-scale pool
        additivityTolerance = 2e9;
    }
}
