// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVMRouter } from "../../../src/routers/SwapVMRouter.sol";
import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";

/**
 * @title VeryImbalancedDifferentDecimals
 * @notice Tests PeggedSwap with very imbalanced pool: 10e18 vs 10e6
 * @dev Token A has 18 decimals, Token B has 6 decimals (like USDC)
 */
contract VeryImbalancedDifferentDecimals is PeggedFeesInvariants {
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

        // Very imbalanced pool: 10e18 vs 10e6
        // TokenA: 10 tokens with 18 decimals = 10e18
        // TokenB: 10 tokens with 6 decimals equivalent = 10e6
        balanceA = 10e18;   // 10 tokens with 18 decimals
        balanceB = 10e6;    // Very small amount (imbalance ratio = 1e12)

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
        // Both become 10e18 after rate scaling
        x0 = 10e18;
        y0 = 10e18;

        // Standard linear width
        linearWidth = 0.8e27;

        // Test amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e17;   // 0.1 tokens
        testAmounts[1] = 5e17;   // 0.5 tokens
        testAmounts[2] = 1e18;   // 1 token

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1e5;   // 0.1 tokens (6 decimals scale)
        testAmountsExactOut[1] = 5e5;   // 0.5 tokens
        testAmountsExactOut[2] = 1e6;   // 1 token

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // Very imbalanced pools with different decimals have higher rounding errors
        // For small amounts (1 wei in 6-dec), sqrt error > swap size
        // Multiple fees add extra rounding, so use 400 bps = 4%
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
        roundingToleranceBps = 400;  // 4%
    }
}
