// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";

/**
 * @title TinyLiquidity
 * @notice Tests ConcentrateXYC + fees with small pool using 6-decimal tokens (USDC-like)
 * @dev Edge case: precision issues with low-decimal tokens and tiny liquidity
 *      Uses 6 decimals so 1e6 = 1 token
 */
contract TinyLiquidity is ConcentrateXYCFeesInvariants {
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
        availableLiquidity = 1000e6;

        // Standard concentration range
        sqrtPriceMin = Math.sqrt(0.8e36);
        sqrtPriceMax = Math.sqrt(1.25e36);

        // Recompute balances with new liquidity
        _computeInitialBalances();

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Test amounts where monotonicity holds (> 0.1% of pool)
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e5;
        testAmounts[1] = 1e6;
        testAmounts[2] = 10e6;

        // Allow 1-wei rounding in additivity
        additivityTolerance = 1;
    }
}
