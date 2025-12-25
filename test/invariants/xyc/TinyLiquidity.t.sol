// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCFeesInvariants } from "../XYCFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";


/**
 * @title TinyLiquidity
 * @notice Tests XYC + fees with small pool using 6-decimal tokens (USDC-like)
 * @dev Edge case: precision issues with low-decimal tokens
 *      Uses 6 decimals so 1e6 = 1 token
 */
contract TinyLiquidity is XYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Replace tokens with 6-decimal versions (like USDC/USDT)
        tokenA = new TokenMockDecimals("Token A", "TKA", 6);
        tokenB = new TokenMockDecimals("Token B", "TKB", 6);

        // Setup tokens for maker
        TokenMockDecimals(address(tokenA)).mint(maker, type(uint128).max);
        TokenMockDecimals(address(tokenB)).mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Small liquidity: 1000 tokens each (1e9 for 6 decimals)
        // Reference trade (1 token) = 0.1% of pool (enough for rounding check)
        balanceA = 1000e6;
        balanceB = 1000e6;

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        flatFeeOutBps = 0.003e9;       // 0.3%
        progressiveFeeInBps = 0.05e9;  // 5%
        progressiveFeeOutBps = 0.05e9; // 5%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Test amounts where monotonicity holds (> 0.1% of pool)
        // Below this, rounding dominates price impact
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e5;   // 0.1 tokens = 0.1% of pool
        testAmounts[1] = 1e6;   // 1 token = 1% of pool
        testAmounts[2] = 10e6;  // 10 tokens = 10% of pool

        // Allow 1-wei rounding in additivity
        additivityTolerance = 1;
    }
}
