// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";

/**
 * @title RoundingInvariants
 * @notice Essential rounding invariants for swap testing
 * @dev Protects against rounding accumulation exploits in both unidirectional and round-trip scenarios
 */
library RoundingInvariants {
    error RoundingAccumulationExploit(uint256 cumulativeOut, uint256 largeSwapOut, uint256 excess);
    error RoundTripProfitDetected(uint256 initialAmount, uint256 finalAmount, uint256 unexpectedProfit);

    /**
     * @notice Test that many tiny swaps don't yield more than one large swap
     * @dev Protects against splitting attacks (A→A→A...)
     */
    function assertNoAccumulationExploit(
        Vm vm_,
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 atomicAmount,
        uint256 iterations,
        bytes memory takerData,
        function(SwapVM, ISwapVM.Order memory, address, address, uint256, bytes memory)
            internal returns (uint256) executeSwap
    ) internal {
        assertNoAccumulationExploitWithTolerance(
            vm_, swapVM, order, tokenIn, tokenOut, atomicAmount, iterations, takerData, executeSwap, 0
        );
    }

    /**
     * @notice Test that many tiny swaps don't yield more than one large swap (with custom tolerance)
     * @dev Protects against splitting attacks (A→A→A...)
     * @param toleranceBps Acceptable difference in basis points (0 = strict, 200 = 2% tolerance for curve-based AMMs)
     */
    function assertNoAccumulationExploitWithTolerance(
        Vm vm_,
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 atomicAmount,
        uint256 iterations,
        bytes memory takerData,
        function(SwapVM, ISwapVM.Order memory, address, address, uint256, bytes memory)
            internal returns (uint256) executeSwap,
        uint256 toleranceBps
    ) internal {
        uint256 snapshot = vm_.snapshot();

        // Execute many tiny swaps
        uint256 cumulativeOut = 0;
        for (uint256 i = 0; i < iterations; i++) {
            cumulativeOut += executeSwap(swapVM, order, tokenIn, tokenOut, atomicAmount, takerData);
        }

        // Restore and execute one large swap
        vm_.revertTo(snapshot);
        uint256 largeSwapOut = executeSwap(swapVM, order, tokenIn, tokenOut, atomicAmount * iterations, takerData);

        // Calculate tolerance
        uint256 tolerance;
        if (toleranceBps == 0) {
            tolerance = iterations; // 1 wei per swap (strict for constant-product AMMs)
        } else {
            // Percentage-based tolerance for curve-based AMMs (e.g., PeggedSwap)
            tolerance = (largeSwapOut * toleranceBps) / 10000;
        }

        // Assert: cumulative should not significantly exceed large swap
        if (cumulativeOut > largeSwapOut + tolerance) {
            revert RoundingAccumulationExploit(cumulativeOut, largeSwapOut, cumulativeOut - largeSwapOut);
        }
    }

    /**
     * @notice Test that round-trip swaps don't accumulate value
     * @dev Protects against ping-pong attacks (A→B→A→B...)
     */
    function assertNoRoundTripProfit(
        Vm vm_,
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenA,
        address tokenB,
        uint256 initialAmount,
        uint256 iterations,
        bytes memory takerData,
        function(SwapVM, ISwapVM.Order memory, address, address, uint256, bytes memory)
            internal returns (uint256) executeSwap
    ) internal {
        uint256 snapshot = vm_.snapshot();

        uint256 currentAmountA = initialAmount;

        // Execute N round-trips: A→B→A
        for (uint256 i = 0; i < iterations; i++) {
            uint256 amountB = executeSwap(swapVM, order, tokenA, tokenB, currentAmountA, takerData);
            currentAmountA = executeSwap(swapVM, order, tokenB, tokenA, amountB, takerData);
        }

        // Assert: should not profit from round-trips
        uint256 tolerance = iterations * 2; // 2 wei per round-trip
        if (currentAmountA > initialAmount + tolerance) {
            revert RoundTripProfitDetected(initialAmount, currentAmountA, currentAmountA - initialAmount);
        }

        // Log value loss (expected with fees)
        if (currentAmountA < initialAmount) {
            console.log("Round-trip loss:", initialAmount - currentAmountA);
        }

        vm_.revertTo(snapshot);
    }

    /**
     * @notice Comprehensive rounding test with multiple scenarios
     * @dev Tests both accumulation and round-trip exploits
     */
    function assertRoundingInvariants(
        Vm vm_,
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenA,
        address tokenB,
        bytes memory takerData,
        function(SwapVM, ISwapVM.Order memory, address, address, uint256, bytes memory)
            internal returns (uint256) executeSwap
    ) internal {
        console.log("\n=== Rounding Invariant Tests ===");

        // Test 1: Accumulation with tiny amounts
        console.log("Test: Tiny swap accumulation (100x 10 wei)");
        assertNoAccumulationExploit(vm_, swapVM, order, tokenA, tokenB, 10, 100, takerData, executeSwap);

        // Test 2: Accumulation with larger amounts
        console.log("Test: Small swap accumulation (50x 1000 wei)");
        assertNoAccumulationExploit(vm_, swapVM, order, tokenA, tokenB, 1000, 50, takerData, executeSwap);

        // Test 3: Round-trip with small amounts
        console.log("Test: Small round-trips (10x 1000 wei)");
        assertNoRoundTripProfit(vm_, swapVM, order, tokenA, tokenB, 1000, 10, takerData, executeSwap);

        // Test 4: Round-trip with medium amounts
        console.log("Test: Medium round-trips (50x 1e18)");
        assertNoRoundTripProfit(vm_, swapVM, order, tokenA, tokenB, 1e18, 50, takerData, executeSwap);

        // Test 5: Stress test - many round-trips
        console.log("Test: Stress round-trips (100x 10e18)");
        assertNoRoundTripProfit(vm_, swapVM, order, tokenA, tokenB, 10e18, 100, takerData, executeSwap);

        console.log("=== All rounding tests passed ===\n");
    }
}

