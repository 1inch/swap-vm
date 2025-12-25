// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

// NOTE: There's currently a compilation issue with the @1inch/aqua dependency
// having incorrect documentation tags. This needs to be fixed in the Aqua package.

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
    uint256 constant BPS = 10_000;

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
        uint256 symmetryTolerance;           // Max allowed difference for symmetry (default: 2 wei)
        uint256 additivityTolerance;         // Max allowed rounding difference for additivity (default: 0)
        uint256 roundingToleranceBps;        // Rounding check tolerance in bps (default: 100 = 1%)
        uint256 monotonicityToleranceBps;    // Monotonicity tolerance in bps (default: 0, strict)
        uint256[] testAmounts;               // Amounts to test with for exactIn (default: [1e18, 10e18, 50e18])
        uint256[] testAmountsExactOut;       // Amounts to test with for exactOut (if empty, uses testAmounts)
        bool skipAdditivity;                 // Skip additivity check (for non-AMM orders)
        bool skipMonotonicity;               // Skip monotonicity check (for flat rate orders)
        bool skipSpotPrice;                  // Skip spot price check (for complex fee structures)
        bool skipSymmetry;                   // Skip symmetry check (for complex fee structures)
        bytes exactInTakerData;              // Custom taker data for exactIn
        bytes exactOutTakerData;             // Custom taker data for exactOut
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

        for (uint256 i = 0; i < config.testAmounts.length; i++) {
            assertQuoteSwapConsistencyInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.testAmounts[i],
                config.exactInTakerData
            );
        }

        // Use testAmountsExactOut if set, otherwise use testAmounts
        uint256[] memory exactOutAmounts = config.testAmountsExactOut.length > 0
            ? config.testAmountsExactOut
            : config.testAmounts;

        for (uint256 i = 0; i < exactOutAmounts.length; i++) {
            assertQuoteSwapConsistencyInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                exactOutAmounts[i],
                config.exactOutTakerData
            );
        }

        if (!config.skipMonotonicity) {
            assertMonotonicityInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.testAmounts,
                config.exactInTakerData,
                config.monotonicityToleranceBps
            );
        }

        if (!config.skipAdditivity) {
            for (uint256 i = 0; i < config.testAmounts.length; i++) {
                assertAdditivityInvariant(
                    swapVM,
                    order,
                    tokenIn,
                    tokenOut,
                    config.testAmounts[i],
                    config.testAmounts[i] * 2,
                    config.exactInTakerData,
                    config.additivityTolerance
                );
            }

            // Use testAmountsExactOut for exactOut additivity if set
            for (uint256 i = 0; i < exactOutAmounts.length; i++) {
                assertAdditivityInvariant(
                    swapVM,
                    order,
                    tokenIn,
                    tokenOut,
                    exactOutAmounts[i],
                    exactOutAmounts[i] * 2,
                    config.exactOutTakerData,
                    config.additivityTolerance
                );
            }
        }

        if (!config.skipSpotPrice) {
            assertRoundingFavorsMakerInvariant(
                swapVM,
                order,
                tokenIn,
                tokenOut,
                config.exactInTakerData,
                config.exactOutTakerData,
                config.roundingToleranceBps
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
     * @param tolerance Max allowed rounding error (in output tokens) for the invariant
     */
    function assertAdditivityInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amountA,
        uint256 amountB,
        bytes memory takerData,
        uint256 tolerance
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

        // Single swap should be at least as good as split swaps (with tolerance)
        // singleOut + tolerance >= splitTotal
        assertGe(
            singleOut + tolerance,
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
                " (diff: ",
                vm.toString(splitTotal > singleOut ? splitTotal - singleOut : 0),
                ", tolerance: ",
                vm.toString(tolerance),
                ")"
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
     * @param toleranceBps Allow larger trade to have better price up to this bps (for dust rounding)
     */
    function assertMonotonicityInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256[] memory amounts,
        bytes memory takerData,
        uint256 toleranceBps
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
            // Allow tolerance for dust where rounding > price impact
            uint256 maxAllowedPrice = prevPrice == type(uint256).max
                ? type(uint256).max
                : prevPrice * (BPS + toleranceBps) / BPS;

            assertLe(
                price,
                maxAllowedPrice,
                string.concat(
                    "Monotonicity violated: price for ",
                    vm.toString(amounts[i]),
                    " (",
                    vm.toString(price),
                    ") > previous price (",
                    vm.toString(prevPrice),
                    ") + ",
                    vm.toString(toleranceBps),
                    " bps tolerance"
                )
            );

            prevPrice = price;
        }
    }

    /**
     * @notice Assert rounding favors maker invariant
     * @dev Small trades shouldn't exceed theoretical spot price
     *      Uses token decimals for proper scaling
     */
    function assertRoundingFavorsMakerInvariant(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        bytes memory exactInTakerData,
        bytes memory exactOutTakerData,
        uint256 toleranceBps
    ) internal view {
        // Get token decimals for proper scaling
        uint8 decimalsIn = IERC20Metadata(tokenIn).decimals();
        uint256 oneTokenIn = 10 ** decimalsIn;
        uint256 precision = 10 ** 18;  // Use 1e18 for rate calculations

        // Test with tiny amounts (few wei)
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1;      // 1 wei
        amounts[1] = 10;     // 10 wei
        amounts[2] = 100;    // 100 wei
        amounts[3] = 1000;   // 1000 wei

        // Get spot price from a 1-token trade (scaled by token decimals)
        (, uint256 spotOut,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, oneTokenIn, exactInTakerData
        );
        // spotPrice = (spotOut * precision) / oneTokenIn
        uint256 spotPrice = (spotOut * precision) / oneTokenIn;

        for (uint256 i = 0; i < amounts.length; i++) {
            // ExactIn: small amount shouldn't get better than spot price
            try swapVM.asView().quote(
                order, tokenIn, tokenOut, amounts[i], exactInTakerData
            ) returns (uint256, uint256 amountOut, bytes32) {
                if (amountOut > 0) {
                    // actualRate = (amountOut * precision) / amounts[i]
                    uint256 actualRate = (amountOut * precision) / amounts[i];

                    assertLe(
                        actualRate,
                        spotPrice * (BPS + toleranceBps) / BPS,
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
                    // inverseRate = (amountIn * precision) / amounts[i]
                    uint256 inverseRate = (amountIn * precision) / amounts[i];
                    // spotInverseRate = precision * precision / spotPrice
                    uint256 spotInverseRate = precision * precision / spotPrice;

                    assertGe(
                        inverseRate,
                        spotInverseRate * (BPS - toleranceBps) / BPS,
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

        uint256[] memory emptyAmounts = new uint256[](0);

        return InvariantConfig({
            symmetryTolerance: 2,  // 2 wei tolerance
            additivityTolerance: 0,  // strict by default
            roundingToleranceBps: 100,  // 1% = 100 bps default
            monotonicityToleranceBps: 0,  // strict by default
            testAmounts: amounts,
            testAmountsExactOut: emptyAmounts,  // Empty = use testAmounts
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
        uint256[] memory emptyAmounts = new uint256[](0);

        return InvariantConfig({
            symmetryTolerance: tolerance,
            additivityTolerance: 0,  // strict by default
            roundingToleranceBps: 100,  // 1% = 100 bps default
            monotonicityToleranceBps: 0,  // strict by default
            testAmounts: testAmounts,
            testAmountsExactOut: emptyAmounts,  // Empty = use testAmounts
            skipAdditivity: false,
            skipMonotonicity: false,
            skipSpotPrice: false,
            skipSymmetry: false,
            exactInTakerData: "",
            exactOutTakerData: ""
        });
    }
}
