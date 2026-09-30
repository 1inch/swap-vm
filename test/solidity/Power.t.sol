// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { Power } from "../../contracts/libs/Power.sol";

/**
 * @title PowerTest
 * @notice Unit tests for the binary exponentiation in `Power.pow`.
 * @notice Tests verify that `Power.pow` behaves like a naive `pow` implementation.
 */
contract PowerTest is Test {
    uint256 internal constant PRECISION = 1e18;

    /// @dev Naive `pow` implementation
    function _naivePow(uint256 base, uint256 exponent, uint256 precision) internal pure returns (uint256 result) {
        result = precision;
        for (uint256 i = 0; i < exponent; i++) {
            result = (result * base) / precision;
        }
    }

    /// @notice `x^0` is the scaled one, whatever the base — the loop must not run.
    function test_ExponentZeroReturnsPrecision() public pure {
        assertEq(Power.pow(2 * PRECISION, 0, PRECISION), PRECISION);
        assertEq(Power.pow(0, 0, PRECISION), PRECISION);
    }

    /// @notice `x^1` is the base itself.
    /// @dev Test mutation `(exponent & 1) == 1` -> `!= 1` / `< 1`: inverting the bit test skips
    /// the only multiplication and leaves `result` at `precision`.
    function test_ExponentOneReturnsBase() public pure {
        assertEq(Power.pow(2 * PRECISION, 1, PRECISION), 2 * PRECISION);
        assertEq(Power.pow(PRECISION / 2, 1, PRECISION), PRECISION / 2);
    }

    /// @notice Every set bit of the exponent must fold into the result, not just the last one.
    /// @dev Kills `exponent & 1` -> `exponent | 1`: `(exponent | 1) == 1` only holds for
    /// exponents 0 and 1, so exponent 3 would yield `base^2` instead of `base^3`.
    function test_OddExponentAccumulatesEveryOneBit() public pure {
        assertEq(Power.pow(2 * PRECISION, 3, PRECISION), 8 * PRECISION);
        assertEq(Power.pow(2 * PRECISION, 5, PRECISION), 32 * PRECISION);
        assertEq(Power.pow(2 * PRECISION, 7, PRECISION), 128 * PRECISION);
    }

    /// @notice Binary exponentiation agrees with repeated multiplication.
    /// @dev Uses `precision = 1` so no intermediate truncation can make the two
    /// orderings of multiplications diverge; bounds keep `base^exponent` in range.
    function testFuzz_MatchesNaiveRepeatedMultiplication(uint256 base, uint256 exponent) public pure {
        base = bound(base, 0, 1000);
        exponent = bound(exponent, 0, 8);
        assertEq(Power.pow(base, exponent, 1), _naivePow(base, exponent, 1));
    }

    /// @notice The loop consumes all 256 exponent bits and terminates on an identity base.
    function test_MaxExponentTerminatesOnIdentityBase() public pure {
        assertEq(Power.pow(PRECISION, type(uint256).max, PRECISION), PRECISION);
    }
}
