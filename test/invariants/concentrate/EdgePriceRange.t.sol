// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISwapVM } from "../../../src/interfaces/ISwapVM.sol";
import { ConcentrateXYCFeesInvariants } from "../ConcentrateXYCFeesInvariants.t.sol";

/**
 * @title EdgePriceRange
 * @notice Tests ConcentrateXYC with various edge case price ranges
 * @dev Tests multiple different price ranges in sequence:
 *      - Asymmetric ranges (0.9-1.5, 0.7-1.1)
 *      - Very narrow (0.99-1.01)
 *      - Standard (0.8-1.25) for baseline comparison
 */
contract EdgePriceRange is ConcentrateXYCFeesInvariants {
    function setUp() public override {
        super.setUp();

        // Standard balanced pool
        availableLiquidity = 1000e18;

        // Will test multiple ranges in different tests
        // Default: standard range
        sqrtPriceMin = Math.sqrt(0.8e36);
        sqrtPriceMax = Math.sqrt(1.25e36);

        // Recompute balances
        _computeInitialBalances();

        // Standard fees
        flatFeeInBps = 0.003e9;        // 0.3%
        protocolFeeOutBps = 0.002e9;   // 0.2%

        // Test amounts
        testAmounts = new uint256[](4);
        testAmounts[0] = 1e18;     // 1 token
        testAmounts[1] = 10e18;    // 10 tokens
        testAmounts[2] = 50e18;    // 50 tokens
        testAmounts[3] = 100e18;   // 100 tokens

        // Tolerances
        symmetryTolerance = 0;
        additivityTolerance = 1;
    }

    /**
     * @notice Test with asymmetric range (skewed up)
     */
    function test_AsymmetricRangeUp() public {
        // Recompute with asymmetric range: 0.9 - 1.5
        sqrtPriceMin = Math.sqrt(0.9e36);
        sqrtPriceMax = Math.sqrt(1.5e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * @notice Test with asymmetric range (skewed down)
     */
    function test_AsymmetricRangeDown() public {
        // Recompute with asymmetric range: 0.85 - 1.15 (more balanced)
        sqrtPriceMin = Math.sqrt(0.85e36);
        sqrtPriceMax = Math.sqrt(1.15e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * @notice Test with very narrow range
     */
    function test_VeryNarrowRange() public {
        // Recompute with very narrow range: 0.99 - 1.01 (±1%)
        sqrtPriceMin = Math.sqrt(0.99e36);
        sqrtPriceMax = Math.sqrt(1.01e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }
}
