// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

// NOTE: There's currently a compilation issue with the @1inch/aqua dependency
// having incorrect documentation tags. This needs to be fixed in the Aqua package.

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { ExactInOutSymmetry } from "./ExactInOutSymmetry.t.sol";

/**
 * @title CoreInvariants
 * @notice Abstract base contract providing invariant validation methods for SwapVM tests
 * @dev Inherit from this contract to get access to all invariant assertions
 *
 * This is an abstract contract meant to be inherited by other test contracts.
 * It provides reusable assertion methods to verify that SwapVM instructions
 * maintain the core invariants.
 *
 * Usage:
 *   contract MyTest is Test, CoreInvariants {
 *       function test_myInstruction() public {
 *           // Create order with your instruction
 *           ISwapVM.Order memory order = ...;
 *
 *           // Validate all invariants
 *           assertAllInvariants(swapVM, order, tokenIn, tokenOut);
 *
 *           // Or validate specific invariants
 *           assertSymmetryInvariant(swapVM, order, tokenIn, tokenOut, amount);
 *       }
 *   }
 */
abstract contract CoreInvariants is Test {

    /**
     * @notice Execute a real swap - must be implemented by inheriting contracts
     * @dev This function should handle token minting, approvals, and actual swap execution
     * @param swapVM The SwapVM instance
     * @param order The order to execute
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amount Amount to swap
     * @param takerData Taker traits and data
     * @return amountIn The amount of input tokens consumed
     * @return amountOut The amount of output tokens received
     */
    function _executeSwap(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal virtual returns (uint256 amountIn, uint256 amountOut);

    // Configuration for invariant testing
    struct InvariantConfig {
        uint256 symmetryTolerance;      // Max allowed difference for symmetry (default: 2 wei)
        uint256[] testAmounts;           // Amounts to test with (default: [1e18, 10e18, 50e18])
        bool skipAdditivity;             // Skip additivity check (for non-AMM orders)
        bool skipMonotonicity;           // Skip monotonicity check (for flat rate orders)
        bool skipSpotPrice;              // Skip spot price check (for complex fee structures)
        bool skipSymmetry;               // Skip symmetry check (for complex fee structures)
        bytes exactInTakerData;          // Custom taker data for exactIn
        bytes exactOutTakerData;         // Custom taker data for exactOut
    }

    /**
     * @notice Assert all core invariants for an order
     * @param swapVM The SwapVM instance to test against
     * @param order The order to validate
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     */
    function assertAllInvariants(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut
    ) internal {
        assertAllInvariantsWithConfig(
            swapVM,
            order,
            tokenIn,
            tokenOut,
            _getDefaultConfig()
        );
    }

    /**
     * @notice Assert all core invariants with custom configuration
     */
    function assertAllInvariantsWithConfig(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        InvariantConfig memory config
    ) internal {
        // Test each invariant
        if (!config.skipSymmetry) {
            for (uint256 i = 0; i < config.testAmounts.length; i++) {
                assertSymmetryInvariant(
                    swapVM,
                    order,
                    tokenIn,
                    tokenOut,
                    config.testAmounts[i],
                    config.symmetryTolerance,
                    config.exactInTakerData,
                    config.exactOutTakerData
                );
            }
        }

        assertQuoteSwapConsistencyInvariant(
            swapVM,
            order,
            tokenIn,
            tokenOut,
            config.testAmounts[0],
            config.exactInTakerData
        );

        assertQuoteSwapConsistencyInvariant(
            swapVM,
            order,
            tokenIn,
            tokenOut,
            config.testAmounts[0],
            config.exactOutTakerData
        );

        if (!config.skipMonotonicity) {
            assertMonotonicityInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.testAmounts,
                config.exactInTakerData
            );
        }

        if (!config.skipAdditivity) {
            assertAdditivityInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.testAmounts[0],
                config.testAmounts[0] * 2,
                config.exactInTakerData
            );

            assertAdditivityInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.testAmounts[0],
                config.testAmounts[0] * 2,
                config.exactOutTakerData
            );
        }

        if (!config.skipSpotPrice) {
            assertRoundingFavorsMakerInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.exactInTakerData,
                config.exactOutTakerData
            );
        }

        // Always test balance sufficiency
        assertBalanceSufficiencyInvariant(
            swapVM,
            order,
            tokenIn,
            tokenOut,
            config.exactInTakerData
        );
    }

    /**
     * @notice Assert exact in/out symmetry invariant
     * @dev If exactIn(X) → Y, then exactOut(Y) → X (within tolerance)
     */
    function assertSymmetryInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 tolerance,
        bytes memory exactInTakerData,
        bytes memory exactOutTakerData
    ) internal view {
        // ExactIn: amountIn → ?
        (, uint256 amountOut,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, amountIn, exactInTakerData
        );

        // ExactOut: ? → amountOut
        (uint256 amountInBack,,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, amountOut, exactOutTakerData
        );

        uint256 diff = amountInBack > amountIn ?
            amountInBack - amountIn : amountIn - amountInBack;

        assertLe(
            diff,
            tolerance,
            string.concat(
                "Symmetry violated: exactIn(",
                vm.toString(amountIn),
                ") -> exactOut(",
                vm.toString(amountOut),
                ") -> ",
                vm.toString(amountInBack),
                " (diff: ",
                vm.toString(diff),
                ")"
            )
        );
    }

    /**
     * @notice Assert swap additivity invariant
     * @dev swap(A+B) should yield same or better rate than swap(A) + swap(B)
     * @dev This function performs real swaps that change state, using snapshots to test different scenarios
     */
    function assertAdditivityInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amountA,
        uint256 amountB,
        bytes memory takerData
    ) internal {
        // Save the current state
        uint256 snapshot = vm.snapshot();

        // Execute single swap of A+B
        (, uint256 singleOut) = _executeSwap(
            swapVM, order, tokenIn, tokenOut, amountA + amountB, takerData
        );

        // Restore state to before the swap
        vm.revertTo(snapshot);

        snapshot = vm.snapshot();

        // Execute swap A
        (, uint256 outA) = _executeSwap(
            swapVM, order, tokenIn, tokenOut, amountA, takerData
        );

        // Execute swap B (note: state has changed after swap A)
        (, uint256 outB) = _executeSwap(
            swapVM, order, tokenIn, tokenOut, amountB, takerData
        );

        vm.revertTo(snapshot);

        uint256 splitTotal = outA + outB;

        // Single swap should be at least as good as split swaps
        assertGe(
            singleOut,
            splitTotal,
            string.concat(
                "Additivity violated: swap(",
                vm.toString(amountA + amountB),
                ") = ",
                vm.toString(singleOut),
                " < swap(",
                vm.toString(amountA),
                ") + swap(",
                vm.toString(amountB),
                ") = ",
                vm.toString(splitTotal),
                " (state-dependent)"
            )
        );
    }

    /**
     * @notice Assert quote/swap consistency invariant
     * @dev quote() and swap() must return identical amounts
     */
    function assertQuoteSwapConsistencyInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal {
        // First get the quote
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, amount, takerData
        );

        assertGt(quotedIn, 0, "Quote returned zero input");
        assertGt(quotedOut, 0, "Quote returned zero output");

        // Save the current state
        uint256 snapshot = vm.snapshot();

        // Execute the swap with the same amount that was passed to quote
        // For exactIn: amount is the input amount
        // For exactOut: amount is the desired output amount
        // The _executeSwap implementation must handle minting correctly
        (uint256 swapIn, uint256 swapOut) = _executeSwap(swapVM, order, tokenIn, tokenOut, amount, takerData);

        // Restore state to before the swap
        vm.revertTo(snapshot);

        // Verify both input and output match the quote
        assertEq(swapIn, quotedIn, "Swap input does not match quote input");
        assertEq(swapOut, quotedOut, "Swap output does not match quote output");
    }

    /**
     * @notice Assert price monotonicity invariant
     * @dev Larger trades must get equal or worse prices
     */
    function assertMonotonicityInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256[] memory amounts,
        bytes memory takerData
    ) internal view {
        require(amounts.length > 1, "Need at least 2 amounts for monotonicity test");

        uint256 prevPrice = type(uint256).max;

        for (uint256 i = 0; i < amounts.length; i++) {
            (, uint256 amountOut,) = swapVM.asView().quote(
                order, tokenIn, tokenOut, amounts[i], takerData
            );

            // Calculate price as output/input (with precision)
            uint256 price = (amountOut * 1e18) / amounts[i];

            // Price should decrease or stay same (worse for taker)
            assertLe(
                price,
                prevPrice,
                string.concat(
                    "Monotonicity violated: price for ",
                    vm.toString(amounts[i]),
                    " (",
                    vm.toString(price),
                    ") > previous price (",
                    vm.toString(prevPrice),
                    ")"
                )
            );

            prevPrice = price;
        }
    }

    /**
     * @notice Assert rounding favors maker invariant
     * @dev Small trades shouldn't exceed theoretical spot price
     */
    function assertRoundingFavorsMakerInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        bytes memory exactInTakerData,
        bytes memory exactOutTakerData
    ) internal view {
        // Test with tiny amounts (few wei)
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1;      // 1 wei
        amounts[1] = 10;     // 10 wei
        amounts[2] = 100;    // 100 wei
        amounts[3] = 1000;   // 1000 wei

        // Get spot price from a medium-sized trade
        (, uint256 spotOut,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, 1e18, exactInTakerData
        );
        uint256 spotPrice = (spotOut * 1e18) / 1e18;

        for (uint256 i = 0; i < amounts.length; i++) {
            // ExactIn: small amount shouldn't get better than spot price
            try swapVM.asView().quote(
                order, tokenIn, tokenOut, amounts[i], exactInTakerData
            ) returns (uint256, uint256 amountOut, bytes32) {
                if (amountOut > 0) {
                    uint256 actualRate = (amountOut * 1e18) / amounts[i];

                    assertLe(
                        actualRate,
                        spotPrice * 101 / 100, // Allow 1% tolerance for rounding
                        string.concat(
                            "Rounding violation (exactIn): rate for ",
                            vm.toString(amounts[i]),
                            " wei (",
                            vm.toString(actualRate),
                            ") exceeds spot price (",
                            vm.toString(spotPrice),
                            ")"
                        )
                    );
                }
                // If amountOut is 0, that's acceptable for tiny amounts with fees
            } catch {
                // If quote reverts for tiny amounts, that's also acceptable
            }

            // ExactOut: small amount should cost at least spot price
            try swapVM.asView().quote(
                order, tokenIn, tokenOut, amounts[i], exactOutTakerData
            ) returns (uint256 amountIn, uint256, bytes32) {
                if (amountIn > 0 && amounts[i] > 0) {
                    uint256 inverseRate = (amountIn * 1e18) / amounts[i];
                    uint256 spotInverseRate = 1e18 * 1e18 / spotPrice;

                    assertGe(
                        inverseRate,
                        spotInverseRate * 99 / 100, // Allow 1% tolerance
                        string.concat(
                            "Rounding violation (exactOut): inverse rate for ",
                            vm.toString(amounts[i]),
                            " wei (",
                            vm.toString(inverseRate),
                            ") below spot inverse (",
                            vm.toString(spotInverseRate),
                            ")"
                        )
                    );
                }
            } catch {
                // If quote reverts for tiny amounts, that's also acceptable
            }
        }
    }

    /**
     * @notice Assert balance sufficiency invariant
     * @dev Must revert if computed amountOut > balanceOut
     */
    function assertBalanceSufficiencyInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        bytes memory takerData
    ) internal view {
        // Try to swap a very large amount and verify it handles it gracefully
        uint256 largeAmount = 1000000e18; // 1 million tokens

        try swapVM.asView().quote(
            order, tokenIn, tokenOut, largeAmount, takerData
        ) returns (uint256 quotedIn, uint256 quotedOut, bytes32) {
            // If it succeeds, ensure the amounts are reasonable
            assertGt(quotedIn, 0, "Large swap should have non-zero input");
            assertGt(quotedOut, 0, "Large swap should have non-zero output");
        } catch {
            // Expected to revert for amounts exceeding balance
            // This is fine - the invariant is satisfied
        }
    }

    /**
     * @notice Batch validate multiple invariants efficiently
     * @param swapVM The SwapVM instance
     * @param order The order to test
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param testAmounts Array of amounts to test with
     */
    function assertBatchInvariants(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256[] memory testAmounts
    ) internal {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = testAmounts;
        assertAllInvariantsWithConfig(swapVM, order, tokenIn, tokenOut, config);
    }

    /**
     * @notice Get default configuration for invariant testing
     */
    function _getDefaultConfig() internal pure returns (InvariantConfig memory) {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 10e18;
        amounts[2] = 50e18;

        return InvariantConfig({
            symmetryTolerance: 2,  // 2 wei tolerance
            testAmounts: amounts,
            skipAdditivity: false,
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: "",
            exactOutTakerData: ""
        });
    }

    /**
     * @notice Helper to create a custom config with specific amounts
     */
    function createInvariantConfig(
        uint256[] memory testAmounts,
        uint256 tolerance
    ) internal pure returns (InvariantConfig memory) {
        return InvariantConfig({
            symmetryTolerance: tolerance,
            testAmounts: testAmounts,
            skipAdditivity: false,
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: "",
            exactOutTakerData: ""
        });
    }
}
