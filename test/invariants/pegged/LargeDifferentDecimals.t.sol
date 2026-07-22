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
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        // Create tokens with correct decimals: 18 and 6
        TokenMock token18 = TokenMock(address(new TokenMockDecimals("Token I", "TKI", 18)));
        TokenMock token6 = TokenMock(address(new TokenMockDecimals("Token J", "TKJ", 6)));

        // Sort so tokenA < tokenB (required by MakerTraitsLib)
        (tokenA, tokenB) = address(token18) < address(token6) ? (token18, token6) : (token6, token18);

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
        // token18: 1M tokens with 18 decimals = 1e24
        // token6:  1M tokens with 6 decimals = 1e12
        // balanceA/balanceB must follow ascending token address order (tokenA, tokenB).
        // We need to scale the 6-decimal token by 1e12 to match the 18-decimal token.
        if (address(token18) < address(token6)) {
            // token18 is Lt (tokenA), token6 is Gt (tokenB)
            balanceA = 1_000_000e18;   // 18 dec
            balanceB = 1_000_000e6;    // 6 dec
            rateLt = 1;      // token18 (18 dec)
            rateGt = 1e12;   // token6 (6 dec) -> scales to 18
        } else {
            // token6 is Lt (tokenA), token18 is Gt (tokenB)
            balanceA = 1_000_000e6;    // 6 dec
            balanceB = 1_000_000e18;   // 18 dec
            rateLt = 1e12;   // token6 (6 dec) -> scales to 18
            rateGt = 1;      // token18 (18 dec)
        }

        // x0 and y0 should match the initial balance * rate for normalization
        // Both become 1e24 after rate scaling
        x0 = 1_000_000e18;
        y0 = 1_000_000e18;  // 1e12 * 1e12 = 1e24 -> after scaling

        // Standard linear width
        linearWidth = 0.8e27;

        // Test amounts - reasonable sizes for 1M pool.
        // Input amounts are in tokenA (input) decimals, exactOut amounts in tokenB (output) decimals.
        uint256 unitIn = address(token18) < address(token6) ? 1e18 : 1e6;   // tokenA decimals
        uint256 unitOut = address(token18) < address(token6) ? 1e6 : 1e18;  // tokenB decimals

        testAmounts = new uint256[](3);
        testAmounts[0] = 1000 * unitIn;    // 1K tokens
        testAmounts[1] = 10_000 * unitIn;  // 10K tokens
        testAmounts[2] = 100_000 * unitIn; // 100K tokens (10% of pool)

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1000 * unitOut;    // 1K tokens
        testAmountsExactOut[1] = 10_000 * unitOut;  // 10K tokens
        testAmountsExactOut[2] = 100_000 * unitOut; // 100K tokens

        flatFeeInBps = 0.003e7;
        flatFeeOutBps = 0.003e7;

        // For different decimals, symmetry error = remainder from floor(deltaY / rateOut)
        // Maximum error = rateOut - 1 ≈ rateOut = 1e12
        // This is expected behavior
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
    }
}
