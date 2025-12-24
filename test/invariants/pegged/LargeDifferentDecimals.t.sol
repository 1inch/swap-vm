// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVMRouter } from "../../../src/routers/SwapVMRouter.sol";
import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";

/**
 * @title LargeDifferentDecimals
 * @notice Tests PeggedSwap with large pool and different decimals: 1M tokens each
 * @dev Token A has 18 decimals, Token B has 6 decimals (like USDC)
 * @dev Large pool size reduces relative rounding error
 */
contract LargeDifferentDecimals is PeggedFeesInvariants {
    function setUp() public override {
        // Skip super.setUp() - do custom initialization
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        // Create tokens with correct decimals: 18 and 6
        tokenA = TokenMock(address(new TokenMockDecimals("Token A", "TKA", 18)));
        tokenB = TokenMock(address(new TokenMockDecimals("Token B", "TKB", 6)));

        // Setup tokens and approvals for maker
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Large pool: 1M tokens each (in respective decimals)
        // TokenA: 1M tokens with 18 decimals = 1e6 * 1e18 = 1e24
        // TokenB: 1M tokens with 6 decimals = 1e6 * 1e6 = 1e12
        balanceA = 1_000_000e18;   // 1M tokens with 18 decimals
        balanceB = 1_000_000e6;    // 1M tokens with 6 decimals

        // Determine rates based on actual token addresses
        // TokenA has 18 decimals, TokenB has 6 decimals
        // We need to scale TokenB by 1e12 to match TokenA
        if (address(tokenA) < address(tokenB)) {
            // tokenA is Lt, tokenB is Gt
            rateLt = 1;      // TokenA (18 dec)
            rateGt = 1e12;   // TokenB (6 dec) -> scales to 18
        } else {
            // tokenB is Lt, tokenA is Gt
            rateLt = 1e12;   // TokenB (6 dec) -> scales to 18
            rateGt = 1;      // TokenA (18 dec)
        }

        // x0 and y0 should match the initial balance * rate for normalization
        // Both become 1e24 after rate scaling
        x0 = 1_000_000e18;
        y0 = 1_000_000e18;  // 1e12 * 1e12 = 1e24 -> after scaling

        // Standard linear width
        linearWidth = 0.8e27;

        // Test amounts - reasonable sizes for 1M pool
        testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;    // 1K tokens
        testAmounts[1] = 10_000e18;  // 10K tokens
        testAmounts[2] = 100_000e18; // 100K tokens (10% of pool)

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1000e6;    // 1K tokens (6 decimals)
        testAmountsExactOut[1] = 10_000e6;  // 10K tokens
        testAmountsExactOut[2] = 100_000e6; // 100K tokens

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // For different decimals, symmetry error = remainder from floor(deltaY / rateOut)
        // Maximum error = rateOut - 1 ≈ rateOut = 1e12
        // This is expected behavior
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
    }
}
