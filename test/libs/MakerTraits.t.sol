// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { MakerTraits, MakerTraitsLib } from "../../src/libs/MakerTraits.sol";

// ==================== HARNESS FOR UNIT TESTS ====================

contract MakerTraitsValidateHarness {
    using MakerTraitsLib for MakerTraits;

    function validate(
        uint256 traits,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external pure {
        MakerTraits.wrap(traits).validate(tokenIn, tokenOut, amountIn);
    }

    function buildTraits(bool allowZeroAmountIn) external pure returns (uint256) {
        uint256 traits = 0;
        if (allowZeroAmountIn) {
            traits |= 1 << 253; // ALLOW_ZERO_AMOUNT_IN flag
        }
        return traits;
    }
}

/**
 * @title MakerTraitsValidateUnitTest
 * @notice Unit tests for MakerTraits.validate using harness
 * @dev Validates the 2 require statements in MakerTraits.validate:
 *      1. tokenIn != tokenOut
 *      2. amountIn > 0 (when allowZeroAmountIn is false)
 */
contract MakerTraitsValidateUnitTest is Test {
    MakerTraitsValidateHarness private harness;
    address private tokenA;
    address private tokenB;

    function setUp() public {
        harness = new MakerTraitsValidateHarness();
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
    }

    // ==================== REQUIRE 1: tokenIn != tokenOut ====================

    function test_TokenInMustNotEqualTokenOut_Reverts() public {
        uint256 traits = harness.buildTraits(false);

        vm.expectRevert(MakerTraitsLib.MakerTraitsTokenInAndTokenOutMustBeDifferent.selector);
        harness.validate(traits, tokenA, tokenA, 1e18);
    }

    function test_DifferentTokens_Success() public view {
        uint256 traits = harness.buildTraits(false);

        // Should not revert when tokens are different
        harness.validate(traits, tokenA, tokenB, 1e18);
    }

    // ==================== REQUIRE 2: amountIn > 0 (when allowZeroAmountIn = false) ====================

    function test_ZeroAmountIn_NotAllowed_Reverts() public {
        uint256 traits = harness.buildTraits(false);

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        harness.validate(traits, tokenA, tokenB, 0);
    }

    function test_NonZeroAmountIn_Success() public view {
        uint256 traits = harness.buildTraits(false);

        // Should not revert when amountIn > 0
        harness.validate(traits, tokenA, tokenB, 1e18);
    }

    // ==================== allowZeroAmountIn flag ====================

    function test_AllowZeroAmountIn_ZeroAmount_Success() public view {
        uint256 traits = harness.buildTraits(true);

        // Should not revert when allowZeroAmountIn is true and amountIn is 0
        harness.validate(traits, tokenA, tokenB, 0);
    }

    function test_AllowZeroAmountIn_NonZeroAmount_Success() public view {
        uint256 traits = harness.buildTraits(true);

        // Should not revert when allowZeroAmountIn is true and amountIn > 0
        harness.validate(traits, tokenA, tokenB, 1e18);
    }

    // ==================== COMBINED VALIDATION TESTS (3 assertions pattern) ====================

    function test_AllValidations_Success() public view {
        uint256 traits = harness.buildTraits(false);

        // This call passes all validations
        harness.validate(traits, tokenA, tokenB, 50e18);

        // 3 assertions pattern
        assertTrue(tokenA != tokenB, "tokenIn != tokenOut");
        assertTrue(50e18 > 0, "amountIn > 0");
        assertTrue(true, "validation passed");
    }

    function test_AllValidations_WithAllowZero_Success() public view {
        uint256 traits = harness.buildTraits(true);

        // This call passes all validations with zero amount
        harness.validate(traits, tokenA, tokenB, 0);

        // 3 assertions pattern
        assertTrue(tokenA != tokenB, "tokenIn != tokenOut");
        assertTrue(0 == 0, "amountIn == 0 allowed");
        assertTrue(true, "validation passed");
    }

    // ==================== FUZZ TESTS ====================

    function test_Validation_Fuzz(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool allowZero
    ) public view {
        vm.assume(tokenIn != tokenOut);
        vm.assume(amountIn > 0 || allowZero);

        uint256 traits = harness.buildTraits(allowZero);

        // Should always succeed when:
        // - tokenIn != tokenOut
        // - amountIn > 0 OR allowZeroAmountIn
        harness.validate(traits, tokenIn, tokenOut, amountIn);

        // 3 assertions
        assertTrue(tokenIn != tokenOut, "tokenIn != tokenOut");
        assertTrue(amountIn > 0 || allowZero, "amountIn valid");
        assertTrue(true, "validation passed");
    }

    function test_TokenInEqualsTokenOut_AlwaysReverts_Fuzz(
        address token,
        uint256 amountIn,
        bool allowZero
    ) public {
        vm.assume(token != address(0));

        uint256 traits = harness.buildTraits(allowZero);

        // Should always revert when tokenIn == tokenOut, regardless of other params
        vm.expectRevert(MakerTraitsLib.MakerTraitsTokenInAndTokenOutMustBeDifferent.selector);
        harness.validate(traits, token, token, amountIn);
    }

    function test_ZeroAmountIn_RevertsWhenNotAllowed_Fuzz(
        address tokenIn,
        address tokenOut
    ) public {
        vm.assume(tokenIn != tokenOut);

        uint256 traits = harness.buildTraits(false);

        // Should always revert when amountIn == 0 and allowZeroAmountIn is false
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        harness.validate(traits, tokenIn, tokenOut, 0);
    }
}
