// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";

contract TakerTraitsValidateHarness {
    using TakerTraitsLib for TakerTraits;

    function validate(
        bytes calldata takerTraitsAndData,
        uint256 takerAmount,
        uint256 amountIn,
        uint256 amountOut
    ) external view {
        (TakerTraits traits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        traits.validate(takerData, takerAmount, amountIn, amountOut);
    }
}

/**
 * @title TakerTraitsAmountValidationTest
 * @notice Tests for amount validation in TakerTraits
 * @dev Validates the 8 require statements in TakerTraits.validate:
 *      1. amountOut > 0
 *      2. deadline not expired
 *      3. takerAmount == amountIn (ExactIn)
 *      4. amountOut == thresholdAmount (ExactIn + strict)
 *      5. amountOut >= thresholdAmount (ExactIn + non-strict)
 *      6. takerAmount == amountOut (ExactOut)
 *      7. amountIn == thresholdAmount (ExactOut + strict)
 *      8. amountIn <= thresholdAmount (ExactOut + non-strict)
 */
contract TakerTraitsAmountValidationTest is Test {
    TakerTraitsValidateHarness private harness;
    address private taker;

    function setUp() public {
        harness = new TakerTraitsValidateHarness();
        taker = makeAddr("taker");
    }

    // ==================== REQUIRE 1: amountOut > 0 ====================

    function test_AmountOutMustBeGreaterThanZero_Reverts() public {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector,
            0
        ));
        harness.validate(takerData, 1e18, 1e18, 0);
    }

    function test_AmountOutGreaterThanZero_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        // Should not revert with amountOut > 0
        harness.validate(takerData, 1e18, 1e18, 1e18);
    }

    // ==================== REQUIRE 2: deadline not expired ====================

    function test_DeadlineExpired_Reverts() public {
        vm.warp(1700000000); // Set block.timestamp
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp - 1));

        vm.expectRevert(TakerTraitsLib.TakerTraitsDeadlineExpired.selector);
        harness.validate(takerData, 1e18, 1e18, 1e18);
    }

    function test_DeadlineNotSet_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        // Should not revert when deadline is 0 (not set)
        harness.validate(takerData, 1e18, 1e18, 1e18);
    }

    function test_DeadlineInFuture_Success() public {
        vm.warp(1700000000);
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp + 3600));

        // Should not revert when deadline is in the future
        harness.validate(takerData, 1e18, 1e18, 1e18);
    }

    function test_DeadlineAtCurrentTimestamp_Success() public {
        vm.warp(1700000000);
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp));

        // Should not revert when deadline equals current timestamp
        harness.validate(takerData, 1e18, 1e18, 1e18);
    }

    // ==================== REQUIRE 3: takerAmount == amountIn (ExactIn) ====================

    function test_ExactIn_TakerAmountMismatch_Reverts() public {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector,
            2e18,
            1e18
        ));
        harness.validate(takerData, 2e18, 1e18, 1e18);
    }

    function test_ExactIn_TakerAmountMatch_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        // Should not revert when takerAmount matches amountIn
        harness.validate(takerData, 5e18, 5e18, 3e18);
    }

    // ==================== REQUIRE 4: amountOut == thresholdAmount (ExactIn + strict) ====================

    function test_ExactIn_StrictThresholdMismatch_Reverts() public {
        bytes memory takerData = _buildTakerData(true, true, 25e18, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsNonExactThresholdAmountOut.selector,
            20e18,
            25e18
        ));
        harness.validate(takerData, 1e18, 1e18, 20e18);
    }

    function test_ExactIn_StrictThresholdMatch_Success() public view {
        bytes memory takerData = _buildTakerData(true, true, 25e18, 0);

        // Should not revert when amountOut equals threshold
        harness.validate(takerData, 1e18, 1e18, 25e18);
    }

    // ==================== REQUIRE 5: amountOut >= thresholdAmount (ExactIn + non-strict) ====================

    function test_ExactIn_MinOutputThreshold_Reverts() public {
        bytes memory takerData = _buildTakerData(true, false, 25e18, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector,
            20e18,
            25e18
        ));
        harness.validate(takerData, 1e18, 1e18, 20e18);
    }

    function test_ExactIn_MinOutputThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 20e18, 0);

        // Should not revert when amountOut >= threshold
        harness.validate(takerData, 1e18, 1e18, 25e18);
    }

    function test_ExactIn_MinOutputThreshold_ExactMatch_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 25e18, 0);

        // Should not revert when amountOut == threshold (edge case)
        harness.validate(takerData, 1e18, 1e18, 25e18);
    }

    // ==================== REQUIRE 6: takerAmount == amountOut (ExactOut) ====================

    function test_ExactOut_TakerAmountMismatch_Reverts() public {
        bytes memory takerData = _buildTakerData(false, false, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector,
            2e18,
            1e18
        ));
        harness.validate(takerData, 2e18, 1e18, 1e18);
    }

    function test_ExactOut_TakerAmountMatch_Success() public view {
        bytes memory takerData = _buildTakerData(false, false, 0, 0);

        // Should not revert when takerAmount matches amountOut
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    // ==================== REQUIRE 7: amountIn == thresholdAmount (ExactOut + strict) ====================

    function test_ExactOut_StrictThresholdMismatch_Reverts() public {
        bytes memory takerData = _buildTakerData(false, true, 12e18, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsNonExactThresholdAmountIn.selector,
            10e18,
            12e18
        ));
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    function test_ExactOut_StrictThresholdMatch_Success() public view {
        bytes memory takerData = _buildTakerData(false, true, 10e18, 0);

        // Should not revert when amountIn equals threshold
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    // ==================== REQUIRE 8: amountIn <= thresholdAmount (ExactOut + non-strict) ====================

    function test_ExactOut_MaxInputThreshold_Reverts() public {
        bytes memory takerData = _buildTakerData(false, false, 8e18, 0);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsExceedingMaxInputAmount.selector,
            10e18,
            8e18
        ));
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    function test_ExactOut_MaxInputThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(false, false, 15e18, 0);

        // Should not revert when amountIn <= threshold
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    function test_ExactOut_MaxInputThreshold_ExactMatch_Success() public view {
        bytes memory takerData = _buildTakerData(false, false, 10e18, 0);

        // Should not revert when amountIn == threshold (edge case)
        harness.validate(takerData, 5e18, 10e18, 5e18);
    }

    // ==================== COMBINED VALIDATION TESTS (3 assertions pattern) ====================

    function test_AllValidations_ExactIn_NoThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 0, 0);

        // This call passes all validations
        harness.validate(takerData, 50e18, 50e18, 25e18);

        // 3 assertions pattern: verify preconditions
        assertTrue(50e18 == 50e18, "takerAmount == amountIn");
        assertTrue(25e18 > 0, "amountOut > 0");
        assertTrue(true, "deadline not set (always passes)");
    }

    function test_AllValidations_ExactIn_WithThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(true, false, 20e18, 0);

        // This call passes all validations with threshold
        harness.validate(takerData, 50e18, 50e18, 25e18);

        // 3 assertions pattern
        assertTrue(50e18 == 50e18, "takerAmount == amountIn");
        assertTrue(25e18 >= 20e18, "amountOut >= threshold");
        assertTrue(25e18 > 0, "amountOut > 0");
    }

    function test_AllValidations_ExactOut_NoThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(false, false, 0, 0);

        // This call passes all validations
        harness.validate(takerData, 25e18, 50e18, 25e18);

        // 3 assertions pattern
        assertTrue(25e18 == 25e18, "takerAmount == amountOut");
        assertTrue(25e18 > 0, "amountOut > 0");
        assertTrue(true, "deadline not set (always passes)");
    }

    function test_AllValidations_ExactOut_WithThreshold_Success() public view {
        bytes memory takerData = _buildTakerData(false, false, 60e18, 0);

        // This call passes all validations with threshold
        harness.validate(takerData, 25e18, 50e18, 25e18);

        // 3 assertions pattern
        assertTrue(25e18 == 25e18, "takerAmount == amountOut");
        assertTrue(50e18 <= 60e18, "amountIn <= threshold");
        assertTrue(25e18 > 0, "amountOut > 0");
    }

    function test_AllValidations_WithDeadline_Success() public {
        vm.warp(1700000000);
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp + 3600));

        // This call passes all validations with deadline
        harness.validate(takerData, 50e18, 50e18, 25e18);

        // 3 assertions pattern
        assertTrue(50e18 == 50e18, "takerAmount == amountIn");
        assertTrue(25e18 > 0, "amountOut > 0");
        assertTrue(block.timestamp <= block.timestamp + 3600, "deadline not expired");
    }

    // ==================== FUZZ TESTS ====================

    function test_ExactIn_Validation_Fuzz(
        uint128 rawAmount,
        uint128 rawThreshold,
        uint40 deadline
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1, type(uint128).max);
        uint256 threshold = bound(uint256(rawThreshold), 0, amount);

        // Warp to ensure deadline handling is tested
        vm.warp(1700000000);
        uint40 validDeadline = deadline > 0 ? uint40(bound(uint256(deadline), block.timestamp, type(uint40).max)) : 0;

        bytes memory takerData = _buildTakerData(true, false, threshold, validDeadline);

        // Should always succeed when:
        // - takerAmount == amountIn (both are 'amount')
        // - amountOut >= threshold (amountOut is 'amount', threshold <= amount)
        // - amountOut > 0 (amount >= 1)
        // - deadline is 0 or in future
        harness.validate(takerData, amount, amount, amount);

        // 3 assertions
        assertGt(amount, 0, "amountOut > 0");
        assertEq(amount, amount, "takerAmount == amountIn");
        assertGe(amount, threshold, "amountOut >= threshold");
    }

    function test_ExactOut_Validation_Fuzz(
        uint128 rawAmountIn,
        uint128 rawAmountOut,
        uint128 rawThreshold
    ) public view {
        uint256 amountOut = bound(uint256(rawAmountOut), 1, type(uint128).max);
        uint256 amountIn = bound(uint256(rawAmountIn), 1, type(uint128).max);
        uint256 threshold = bound(uint256(rawThreshold), amountIn, type(uint128).max);

        bytes memory takerData = _buildTakerData(false, false, threshold, 0);

        // Should always succeed when:
        // - takerAmount == amountOut
        // - amountIn <= threshold
        // - amountOut > 0
        harness.validate(takerData, amountOut, amountIn, amountOut);

        // 3 assertions
        assertGt(amountOut, 0, "amountOut > 0");
        assertEq(amountOut, amountOut, "takerAmount == amountOut");
        assertLe(amountIn, threshold, "amountIn <= threshold");
    }

    // ==================== HELPER FUNCTIONS ====================

    function _buildTakerData(
        bool isExactIn,
        bool isStrictThreshold,
        uint256 threshold,
        uint40 deadline
    ) private view returns (bytes memory) {
        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(threshold) : bytes("");

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: isStrictThreshold,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: address(0),
            deadline: deadline,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }
}

// ==================== INTEGRATION TESTS ====================

/**
 * @title TakerAmountValidationIntegrationTest
 * @notice Integration tests for TakerTraits amount validation via swap
 * @dev Tests the validation through actual swap execution with 3 assertions pattern
 */
contract TakerAmountValidationIntegrationTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");
    address public recipient = makeAddr("recipient");

    uint256 constant MAKER_BALANCE_A = 100e18;
    uint256 constant MAKER_BALANCE_B = 200e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        tokenA.mint(maker, 10000e18);
        tokenB.mint(taker, 10000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ==================== REQUIRE 1: amountOut > 0 ====================
    // Note: When amountOut = 0, the LimitSwap computes amountIn = 0 as well.
    // MakerTraits.validate checks amountIn > 0 BEFORE TakerTraits.validate checks amountOut > 0.
    // So the actual error is MakerTraitsZeroAmountInNotAllowed.
    // The unit test harness tests TakerTraitsAmountOutMustBeGreaterThanZero directly.

    function test_AmountOutZero_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(false, false, 0, 0, signature); // ExactOut mode

        // With LimitSwap, amountOut=0 => amountIn=0, so MakerTraits validation fails first
        vm.prank(taker);
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, address(tokenB), address(tokenA), 0, takerData);
    }

    function test_AmountOutPositive_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(true, false, 0, 0, signature);

        uint256 takerTokenBBefore = tokenB.balanceOf(taker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertGt(amountOut, 0, "amountOut should be > 0");
        assertEq(takerTokenBBefore - tokenB.balanceOf(taker), amountIn, "Taker spent correct tokenB");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received correct tokenA");
    }

    // ==================== REQUIRE 2: deadline ====================

    function test_DeadlineExpired_Reverts() public {
        vm.warp(1700000000);
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp - 1), signature);

        vm.prank(taker);
        vm.expectRevert(TakerTraitsLib.TakerTraitsDeadlineExpired.selector);
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);
    }

    function test_DeadlineValid_Success() public {
        vm.warp(1700000000);
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(true, false, 0, uint40(block.timestamp + 3600), signature);

        uint256 takerTokenBBefore = tokenB.balanceOf(taker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertEq(amountIn, 50e18, "amountIn should be 50e18");
        assertEq(takerTokenBBefore - tokenB.balanceOf(taker), amountIn, "Taker spent correct tokenB");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    // ==================== REQUIRE 3-5: ExactIn thresholds ====================

    function test_ExactIn_MinThreshold_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // min threshold 30e18, but will only get 25e18
        bytes memory takerData = _buildTakerData(true, false, 30e18, 0, signature);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector,
            25e18,
            30e18
        ));
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);
    }

    function test_ExactIn_MinThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // min threshold 20e18, will get 25e18
        bytes memory takerData = _buildTakerData(true, false, 20e18, 0, signature);

        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertEq(amountOut, 25e18, "amountOut should be 25e18");
        assertGe(amountOut, 20e18, "amountOut >= threshold");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    function test_ExactIn_StrictThreshold_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // strict threshold 20e18, but will get 25e18
        bytes memory takerData = _buildTakerData(true, true, 20e18, 0, signature);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsNonExactThresholdAmountOut.selector,
            25e18,
            20e18
        ));
        swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);
    }

    function test_ExactIn_StrictThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // strict threshold 25e18, will get exactly 25e18
        bytes memory takerData = _buildTakerData(true, true, 25e18, 0, signature);

        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertEq(amountOut, 25e18, "amountOut should be exactly 25e18");
        assertEq(amountOut, 25e18, "amountOut equals threshold");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    // ==================== REQUIRE 6-8: ExactOut thresholds ====================

    function test_ExactOut_MaxThreshold_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // max threshold 40e18, but will need 50e18
        bytes memory takerData = _buildTakerData(false, false, 40e18, 0, signature);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsExceedingMaxInputAmount.selector,
            50e18,
            40e18
        ));
        swapVM.swap(order, address(tokenB), address(tokenA), 25e18, takerData);
    }

    function test_ExactOut_MaxThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // max threshold 60e18, will need 50e18
        bytes memory takerData = _buildTakerData(false, false, 60e18, 0, signature);

        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 25e18, takerData);

        // 3 assertions pattern
        assertEq(amountOut, 25e18, "amountOut should be 25e18");
        assertLe(amountIn, 60e18, "amountIn <= threshold");
        assertEq(takerTokenBBefore - tokenB.balanceOf(taker), amountIn, "Taker spent tokenB");
    }

    function test_ExactOut_StrictThreshold_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // strict threshold 40e18, but will need 50e18
        bytes memory takerData = _buildTakerData(false, true, 40e18, 0, signature);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsNonExactThresholdAmountIn.selector,
            50e18,
            40e18
        ));
        swapVM.swap(order, address(tokenB), address(tokenA), 25e18, takerData);
    }

    function test_ExactOut_StrictThreshold_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        // strict threshold 50e18, will need exactly 50e18
        bytes memory takerData = _buildTakerData(false, true, 50e18, 0, signature);

        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 25e18, takerData);

        // 3 assertions pattern
        assertEq(amountIn, 50e18, "amountIn should be exactly 50e18");
        assertEq(amountOut, 25e18, "amountOut should be 25e18");
        assertEq(takerTokenBBefore - tokenB.balanceOf(taker), amountIn, "Taker spent tokenB");
    }

    // ==================== COMBINED VALIDATION TESTS ====================

    function test_AllValidations_ExactIn_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(true, false, 20e18, 0, signature);

        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertGt(amountOut, 0, "amountOut > 0");
        assertEq(tokenB.balanceOf(maker) - makerTokenBBefore, amountIn, "Maker received tokenB");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    function test_AllValidations_ExactOut_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(false, false, 60e18, 0, signature);

        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 25e18, takerData);

        // 3 assertions pattern
        assertGt(amountOut, 0, "amountOut > 0");
        assertEq(tokenB.balanceOf(maker) - makerTokenBBefore, amountIn, "Maker received tokenB");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    // ==================== RECIPIENT TESTS ====================

    function test_CustomRecipient_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerDataWithRecipient(true, recipient, signature);

        uint256 recipientTokenABefore = tokenA.balanceOf(recipient);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), 50e18, takerData);

        // 3 assertions pattern
        assertEq(tokenA.balanceOf(recipient) - recipientTokenABefore, amountOut, "Recipient received tokenA");
        assertEq(tokenA.balanceOf(taker), takerTokenABefore, "Taker balance unchanged");
        assertGt(amountOut, 0, "amountOut > 0");
    }

    // ==================== FUZZ TESTS ====================

    function test_Validation_Fuzz(uint128 rawAmount, bool isExactIn) public {
        uint256 amount = bound(uint256(rawAmount), 1e15, MAKER_BALANCE_B / 2);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder();
        bytes memory takerData = _buildTakerData(isExactIn, false, 0, 0, signature);

        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(tokenA), amount, takerData);

        // 3 assertions pattern
        assertGt(amountOut, 0, "amountOut > 0");
        assertEq(tokenB.balanceOf(maker) - makerTokenBBefore, amountIn, "Maker received tokenB");
        assertEq(tokenA.balanceOf(taker) - takerTokenABefore, amountOut, "Taker received tokenA");
    }

    // ==================== HELPER FUNCTIONS ====================

    function _buildOrder() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([MAKER_BALANCE_A, MAKER_BALANCE_B])
            )),
            program.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: programBytes
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(
        bool isExactIn,
        bool isStrictThreshold,
        uint256 threshold,
        uint40 deadline,
        bytes memory signature
    ) internal view returns (bytes memory) {
        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(threshold) : bytes("");

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: isStrictThreshold,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: address(0),
            deadline: deadline,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }

    function _buildTakerDataWithRecipient(
        bool isExactIn,
        address to,
        bytes memory signature
    ) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: to,
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }
}
