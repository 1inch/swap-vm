// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright (c) 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";

/// @dev Exposes the internal library functions for direct unit testing.
contract ConcentrateBuilderWrapper {
    function build2D(uint256 sqrtPriceMin, uint256 sqrtPriceMax) external pure returns (bytes memory) {
        return XYCConcentrateArgsBuilder.build2D(sqrtPriceMin, sqrtPriceMax);
    }

    function computeBalances(uint256 targetL, uint256 sqrtPspot, uint256 sqrtPmin, uint256 sqrtPmax)
        external pure returns (uint256 bLt, uint256 bGt)
    {
        return XYCConcentrateArgsBuilder.computeBalances(targetL, sqrtPspot, sqrtPmin, sqrtPmax);
    }

    function computeLiquidityFromAmounts(
        uint256 availableLt,
        uint256 availableGt,
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) external pure returns (uint256 targetL, uint256 actualLt, uint256 actualGt) {
        return XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(availableLt, availableGt, sqrtPspot, sqrtPmin, sqrtPmax);
    }
}

/// @title XYCConcentrateArgsBuilder direct unit tests
/// @notice Covers price-bound validation and the exact liquidity-from-amounts math against
///         independently computed reference values. The other concentrate suites feed these
///         helpers' outputs straight back into a self-consistent pool and only assert relational
///         properties (e.g. quote == swap), so the absolute results are verified directly here.
contract XYCConcentrateArgsBuilderTest is Test {
    uint256 constant ONE = 1e18;

    ConcentrateBuilderWrapper internal w;

    function setUp() public {
        w = new ConcentrateBuilderWrapper();
    }

    // ── Price-bound validation ──────────────────────────────────────────────────

    function test_Build2D_Revert_ZeroMin() public {
        vm.expectRevert(abi.encodeWithSelector(
            XYCConcentrateArgsBuilder.ConcentrateInvalidPriceBounds.selector, uint256(0), ONE
        ));
        w.build2D(0, ONE);
    }

    function test_Build2D_Revert_MinAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(
            XYCConcentrateArgsBuilder.ConcentrateInvalidPriceBounds.selector, 2 * ONE, ONE
        ));
        w.build2D(2 * ONE, ONE);
    }

    function test_Build2D_Revert_MinEqualsMax() public {
        vm.expectRevert(abi.encodeWithSelector(
            XYCConcentrateArgsBuilder.ConcentrateInvalidPriceBounds.selector, ONE, ONE
        ));
        w.build2D(ONE, ONE);
    }

    function test_Build2D_Valid_Succeeds() public view {
        bytes memory out = w.build2D(ONE / 2, 2 * ONE);
        assertEq(out.length, 64, "valid build2D must encode two 32-byte words");
    }

    function test_ComputeBalances_Revert_MinAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(
            XYCConcentrateArgsBuilder.ConcentrateInvalidPriceBounds.selector, 2 * ONE, ONE
        ));
        w.computeBalances(100e18, ONE, 2 * ONE, ONE);
    }

    function test_ComputeLiquidityFromAmounts_Revert_MinAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(
            XYCConcentrateArgsBuilder.ConcentrateInvalidPriceBounds.selector, 2 * ONE, ONE
        ));
        w.computeLiquidityFromAmounts(100e18, 100e18, ONE, 2 * ONE, ONE);
    }

    // ── Exact liquidity-from-amounts (Lt is the binding constraint) ──────────────

    /// @notice Range [0.25, 4] (sqrtPmin=0.5, sqrtPmax=2), spot P=1. With availableLt=50 and
    ///         availableGt=100, the Lt side binds:
    ///           lFromLt = 50 * (2*1) / (2-1) = 100
    ///           lFromGt = 100 * 1 / (1-0.5) = 200   -> targetL = 100
    ///           bLt = bGt = 100 * (1-0.5) = 50
    ///         Verifies the `sqrtPmax > sqrtPspot` branch and the `sqrtPmax - sqrtPspot`
    ///         denominator produce the expected single-sided liquidity split.
    function test_ComputeLiquidityFromAmounts_ExactValues_LtBinds() public view {
        (uint256 targetL, uint256 actualLt, uint256 actualGt) =
            w.computeLiquidityFromAmounts(50e18, 100e18, ONE, ONE / 2, 2 * ONE);

        assertEq(targetL, 100e18, "targetL must be the Lt-bound value (100)");
        assertEq(actualLt, 50e18, "actualLt must be 50");
        assertEq(actualGt, 50e18, "actualGt must be 50");
    }

    /// @notice Mirror case where the Gt side binds, for completeness.
    function test_ComputeLiquidityFromAmounts_ExactValues_GtBinds() public view {
        (uint256 targetL, uint256 actualLt, uint256 actualGt) =
            w.computeLiquidityFromAmounts(100e18, 50e18, ONE, ONE / 2, 2 * ONE);

        // lFromLt = 100*2/1 = 200 ; lFromGt = 50*1/0.5 = 100 -> targetL = 100
        assertEq(targetL, 100e18, "targetL must be the Gt-bound value (100)");
        assertEq(actualLt, 50e18, "actualLt must be 50");
        assertEq(actualGt, 50e18, "actualGt must be 50");
    }
}
