// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";


/**
 * @title BalancedPoolEdgeFees
 * @notice Tests PeggedSwap + fees with balanced pool and edge case fee values
 * @dev Edge case: testing boundary fee values (near 0 and near max)
 */
contract BalancedPoolEdgeFees is PeggedFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Balanced pool
        balanceA = 1000e18;
        balanceB = 1000e18;
        x0 = 1000e18;
        y0 = 1000e18;
        linearWidth = 0.8e27;

        // Edge case fees - near maximum allowed
        flatFeeInBps = 0.999e9;        // 99.9% (near max)
        flatFeeOutBps = 0.001e9;       // 0.1% (near min meaningful)
        progressiveFeeInBps = 0.5e9;   // 50%
        progressiveFeeOutBps = 0.5e9;  // 50%
        protocolFeeOutBps = 0.1e9;     // 10%

        // Standard test amounts for exactIn
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;

        // Small exactOut amounts (99.9% fee requires 1000x input)
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 0.1e18;
        testAmountsExactOut[1] = 0.5e18;
        testAmountsExactOut[2] = 1e18;

        // Edge case fees have higher errors
        symmetryTolerance = 2100;
        additivityTolerance = 2100;
        // Skip spot price check for 99.9% fee (causes overflow in tolerance calc)
        skipSpotPrice = true;
    }
}
