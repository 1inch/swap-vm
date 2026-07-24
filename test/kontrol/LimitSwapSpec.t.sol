// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { LimitSwapHarness } from "./harnesses/LimitSwapHarness.sol";

/// @notice Kontrol specification for the LimitSwap instructions (opcodes 0x53, 0x54).
///
/// @dev Reference semantics, from src/instructions/LimitSwap.sol:
///
///        exactIn:   amountOut = floor(amountIn * balanceOut / balanceIn)
///        exactOut:  amountIn  = ceil (amountOut * balanceIn / balanceOut)
///
///      This is a fixed exchange rate — the same `mulDiv` skeleton as XYCSwap but with a
///      constant denominator instead of `balanceIn + amountIn`. The two instructions are
///      specified together deliberately: they share the arithmetic that the lemma library
///      in lemmas.k exists to discharge, so they should succeed or fail together.
///
///      LimitSwap additionally requires `makerDirectionLt == (tokenIn < tokenOut)`. The
///      maker signs the direction into the program, so a taker cannot reinterpret a sell
///      order as a buy order by swapping the token arguments.
contract LimitSwapSpec is Test {
    LimitSwapHarness internal harness;

    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function setUp() public {
        harness = new LimitSwapHarness();
    }

    /// @dev Args encode a single byte: whether the maker signed `tokenIn < tokenOut`.
    function _args(bool makerDirectionLt) internal pure returns (bytes memory) {
        return abi.encodePacked(makerDirectionLt);
    }

    // -----------------------------------------------------------------------
    // Rounding direction
    // -----------------------------------------------------------------------

    /// @notice The quoted output never exceeds the exact rate.
    function test_exactIn_roundsInFavourOfMaker(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) public view {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);
        vm.assume(amountIn <= type(uint256).max / balanceOut);

        uint256 amountOut = harness.exactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, _args(true));

        assertLe(amountOut * balanceIn, amountIn * balanceOut, "flooring must not round the output up");
    }

    /// @notice The taker's required input is never rounded down.
    function test_exactOut_roundsInFavourOfMaker(uint256 balanceIn, uint256 balanceOut, uint256 amountOut)
        public
        view
    {
        vm.assume(balanceIn > 0 && balanceIn < 2 ** 128);
        vm.assume(balanceOut > 0 && balanceOut < 2 ** 128);
        vm.assume(amountOut < 2 ** 128);

        uint256 amountIn = harness.exactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, _args(true));

        assertGe(amountIn * balanceOut, amountOut * balanceIn, "ceiling must not round the input down");
    }

    /// @notice Ceiling and floor differ by strictly less than one unit of the divisor.
    /// @dev Pins the rounding to *exactly* ceil, not merely "at least floor". Without this
    ///      an implementation could round arbitrarily far up and still satisfy the
    ///      inequality above, which would silently overcharge takers.
    function test_exactOut_roundingIsTight(uint256 balanceIn, uint256 balanceOut, uint256 amountOut) public view {
        vm.assume(balanceIn > 0 && balanceIn < 2 ** 128);
        vm.assume(balanceOut > 0 && balanceOut < 2 ** 128);
        vm.assume(amountOut < 2 ** 128);

        uint256 amountIn = harness.exactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, _args(true));

        assertLt(
            (amountIn * balanceOut) - (amountOut * balanceIn),
            balanceOut,
            "ceiling must not overshoot by a whole divisor"
        );
    }

    /// @notice Zero input yields zero output.
    function test_exactIn_zeroInputYieldsZeroOutput(uint256 balanceIn, uint256 balanceOut) public view {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);

        uint256 amountOut = harness.exactIn(balanceIn, balanceOut, 0, TOKEN_LO, TOKEN_HI, _args(true));

        assertEq(amountOut, 0, "zero input must yield zero output");
    }

    // -----------------------------------------------------------------------
    // Direction guard
    // -----------------------------------------------------------------------

    /// @notice A taker cannot execute the order in the direction the maker did not sign.
    function test_exactIn_revertsOnDirectionMismatch(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) public {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);

        // Maker signed `tokenIn < tokenOut`, taker presents the tokens the other way round.
        vm.expectRevert();
        harness.exactIn(balanceIn, balanceOut, amountIn, TOKEN_HI, TOKEN_LO, _args(true));
    }

    // -----------------------------------------------------------------------
    // Balance guards
    // -----------------------------------------------------------------------

    function test_exactIn_revertsOnZeroBalanceIn(uint256 balanceOut, uint256 amountIn) public {
        vm.expectRevert();
        harness.exactIn(0, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, _args(true));
    }

    function test_exactIn_revertsOnZeroBalanceOut(uint256 balanceIn, uint256 amountIn) public {
        vm.assume(balanceIn > 0);
        vm.expectRevert();
        harness.exactIn(balanceIn, 0, amountIn, TOKEN_LO, TOKEN_HI, _args(true));
    }

    // -----------------------------------------------------------------------
    // All-or-nothing variant
    // -----------------------------------------------------------------------

    /// @notice The full-amount variant pays out the entire output balance when the taker
    ///         supplies exactly the input balance.
    function test_onlyFull_exactIn_paysEntireBalance(uint256 balanceIn, uint256 balanceOut) public view {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);

        uint256 amountOut = harness.exactInOnlyFull(balanceIn, balanceOut, balanceIn, TOKEN_LO, TOKEN_HI, _args(true));

        assertEq(amountOut, balanceOut, "a full fill must pay the entire output balance");
    }

    /// @notice A partial fill is rejected by the all-or-nothing variant.
    function test_onlyFull_exactIn_revertsOnPartialFill(uint256 balanceIn, uint256 balanceOut, uint256 amountIn)
        public
    {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);
        vm.assume(amountIn != balanceIn);

        vm.expectRevert();
        harness.exactInOnlyFull(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, _args(true));
    }
}
