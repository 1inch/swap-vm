// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { TakerTraits, TakerTraitsLib } from "../../src/libs/TakerTraits.sol";

/// @dev Harness to test internal functions via external calls
contract TakerTraitsHarness {
    using TakerTraitsLib for TakerTraits;

    function parse(bytes calldata data) external pure returns (TakerTraits traits, bytes calldata tail) {
        return TakerTraitsLib.parse(data);
    }

    function validate(
        bytes calldata takerTraitsAndData,
        uint256 takerAmount,
        uint256 amountIn,
        uint256 amountOut
    ) external view {
        (TakerTraits traits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        traits.validate(takerData, takerAmount, amountIn, amountOut);
    }

    function threshold(bytes calldata takerTraitsAndData) external pure returns (bool hasThreshold, uint256 thresholdAmount) {
        (TakerTraits traits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        return traits.threshold(takerData);
    }

    function to(bytes calldata takerTraitsAndData, address taker) external pure returns (address) {
        (TakerTraits traits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        return traits.to(takerData, taker);
    }

    function deadline(bytes calldata takerTraitsAndData) external pure returns (uint40) {
        (TakerTraits traits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        return traits.deadline(takerData);
    }
}

/**
 * @title TakerTraitsFlagsTest
 * @notice Unit and fuzz tests for TakerTraits flag getters
 * @dev Tests all flag extraction functions with explicit and fuzz inputs
 */
contract TakerTraitsFlagsTest is Test {
    using TakerTraitsLib for TakerTraits;

    // ==================== Flag Bit Constants ====================

    uint16 private constant _IS_EXACT_IN_BIT_FLAG = 0x0001;
    uint16 private constant _SHOULD_UNWRAP_BIT_FLAG = 0x0002;
    uint16 private constant _HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG = 0x0004;
    uint16 private constant _HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG = 0x0008;
    uint16 private constant _IS_STRICT_THRESHOLD_BIT_FLAG = 0x0010;
    uint16 private constant _IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG = 0x0020;
    uint16 private constant _USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG = 0x0040;

    // ==================== isExactIn Flag Tests ====================

    function test_IsExactIn_True() public pure {
        assertTrue(TakerTraits.wrap(_IS_EXACT_IN_BIT_FLAG).isExactIn());
    }

    function test_IsExactIn_False() public pure {
        assertFalse(TakerTraits.wrap(0).isExactIn());
    }

    function test_IsExactIn_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _IS_EXACT_IN_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).isExactIn(), expected);
    }

    // ==================== shouldUnwrapWeth Flag Tests ====================

    function test_ShouldUnwrapWeth_True() public pure {
        assertTrue(TakerTraits.wrap(_SHOULD_UNWRAP_BIT_FLAG).shouldUnwrapWeth());
    }

    function test_ShouldUnwrapWeth_False() public pure {
        assertFalse(TakerTraits.wrap(0).shouldUnwrapWeth());
    }

    function test_ShouldUnwrapWeth_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _SHOULD_UNWRAP_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).shouldUnwrapWeth(), expected);
    }

    // ==================== hasPreTransferInCallback Flag Tests ====================

    function test_HasPreTransferInCallback_True() public pure {
        assertTrue(TakerTraits.wrap(_HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG).hasPreTransferInCallback());
    }

    function test_HasPreTransferInCallback_False() public pure {
        assertFalse(TakerTraits.wrap(0).hasPreTransferInCallback());
    }

    function test_HasPreTransferInCallback_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).hasPreTransferInCallback(), expected);
    }

    // ==================== hasPreTransferOutCallback Flag Tests ====================

    function test_HasPreTransferOutCallback_True() public pure {
        assertTrue(TakerTraits.wrap(_HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG).hasPreTransferOutCallback());
    }

    function test_HasPreTransferOutCallback_False() public pure {
        assertFalse(TakerTraits.wrap(0).hasPreTransferOutCallback());
    }

    function test_HasPreTransferOutCallback_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).hasPreTransferOutCallback(), expected);
    }

    // ==================== isStrictThresholdAmount Flag Tests ====================

    function test_IsStrictThresholdAmount_True() public pure {
        assertTrue(TakerTraits.wrap(_IS_STRICT_THRESHOLD_BIT_FLAG).isStrictThresholdAmount());
    }

    function test_IsStrictThresholdAmount_False() public pure {
        assertFalse(TakerTraits.wrap(0).isStrictThresholdAmount());
    }

    function test_IsStrictThresholdAmount_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _IS_STRICT_THRESHOLD_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).isStrictThresholdAmount(), expected);
    }

    // ==================== isFirstTransferFromTaker Flag Tests ====================

    function test_IsFirstTransferFromTaker_True() public pure {
        assertTrue(TakerTraits.wrap(_IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG).isFirstTransferFromTaker());
    }

    function test_IsFirstTransferFromTaker_False() public pure {
        assertFalse(TakerTraits.wrap(0).isFirstTransferFromTaker());
    }

    function test_IsFirstTransferFromTaker_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).isFirstTransferFromTaker(), expected);
    }

    // ==================== useTransferFromAndAquaPush Flag Tests ====================

    function test_UseTransferFromAndAquaPush_True() public pure {
        assertTrue(TakerTraits.wrap(_USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG).useTransferFromAndAquaPush());
    }

    function test_UseTransferFromAndAquaPush_False() public pure {
        assertFalse(TakerTraits.wrap(0).useTransferFromAndAquaPush());
    }

    function test_UseTransferFromAndAquaPush_Fuzz(uint176 rawTraits) public pure {
        bool expected = (rawTraits & _USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG) != 0;
        assertEq(TakerTraits.wrap(rawTraits).useTransferFromAndAquaPush(), expected);
    }

    // ==================== Combined Flags Tests ====================

    function test_AllFlagsSet() public pure {
        uint16 allFlags = _IS_EXACT_IN_BIT_FLAG |
            _SHOULD_UNWRAP_BIT_FLAG |
            _HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG |
            _HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG |
            _IS_STRICT_THRESHOLD_BIT_FLAG |
            _IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG |
            _USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG;

        TakerTraits traits = TakerTraits.wrap(allFlags);

        assertTrue(traits.isExactIn());
        assertTrue(traits.shouldUnwrapWeth());
        assertTrue(traits.hasPreTransferInCallback());
        assertTrue(traits.hasPreTransferOutCallback());
        assertTrue(traits.isStrictThresholdAmount());
        assertTrue(traits.isFirstTransferFromTaker());
        assertTrue(traits.useTransferFromAndAquaPush());
    }

    function test_NoFlagsSet() public pure {
        TakerTraits traits = TakerTraits.wrap(0);

        assertFalse(traits.isExactIn());
        assertFalse(traits.shouldUnwrapWeth());
        assertFalse(traits.hasPreTransferInCallback());
        assertFalse(traits.hasPreTransferOutCallback());
        assertFalse(traits.isStrictThresholdAmount());
        assertFalse(traits.isFirstTransferFromTaker());
        assertFalse(traits.useTransferFromAndAquaPush());
    }

    function test_AllFlags_Fuzz(
        bool isExactIn,
        bool shouldUnwrap,
        bool hasPreIn,
        bool hasPreOut,
        bool isStrict,
        bool isFirstFromTaker,
        bool useAquaPush
    ) public pure {
        uint16 rawFlags = (isExactIn ? _IS_EXACT_IN_BIT_FLAG : 0) |
            (shouldUnwrap ? _SHOULD_UNWRAP_BIT_FLAG : 0) |
            (hasPreIn ? _HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG : 0) |
            (hasPreOut ? _HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG : 0) |
            (isStrict ? _IS_STRICT_THRESHOLD_BIT_FLAG : 0) |
            (isFirstFromTaker ? _IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG : 0) |
            (useAquaPush ? _USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG : 0);

        TakerTraits traits = TakerTraits.wrap(rawFlags);

        assertEq(traits.isExactIn(), isExactIn);
        assertEq(traits.shouldUnwrapWeth(), shouldUnwrap);
        assertEq(traits.hasPreTransferInCallback(), hasPreIn);
        assertEq(traits.hasPreTransferOutCallback(), hasPreOut);
        assertEq(traits.isStrictThresholdAmount(), isStrict);
        assertEq(traits.isFirstTransferFromTaker(), isFirstFromTaker);
        assertEq(traits.useTransferFromAndAquaPush(), useAquaPush);
    }

    function test_FlagsAreIndependent_Fuzz(uint176 rawTraits) public pure {
        TakerTraits traits = TakerTraits.wrap(rawTraits);

        assertEq(traits.isExactIn(), (rawTraits & _IS_EXACT_IN_BIT_FLAG) != 0);
        assertEq(traits.shouldUnwrapWeth(), (rawTraits & _SHOULD_UNWRAP_BIT_FLAG) != 0);
        assertEq(traits.hasPreTransferInCallback(), (rawTraits & _HAS_PRE_TRANSFER_IN_CALLBACK_BIT_FLAG) != 0);
        assertEq(traits.hasPreTransferOutCallback(), (rawTraits & _HAS_PRE_TRANSFER_OUT_CALLBACK_BIT_FLAG) != 0);
        assertEq(traits.isStrictThresholdAmount(), (rawTraits & _IS_STRICT_THRESHOLD_BIT_FLAG) != 0);
        assertEq(traits.isFirstTransferFromTaker(), (rawTraits & _IS_FIRST_TRANSFER_FROM_TAKER_BIT_FLAG) != 0);
        assertEq(traits.useTransferFromAndAquaPush(), (rawTraits & _USE_TRANSFER_FROM_AND_AQUA_PUSH_FLAG) != 0);
    }
}

/**
 * @title TakerTraitsBuildTest
 * @notice Tests for TakerTraitsLib.build function
 */
contract TakerTraitsBuildTest is Test {
    using TakerTraitsLib for TakerTraits;

    TakerTraitsHarness private harness;
    address private taker;

    function setUp() public {
        harness = new TakerTraitsHarness();
        taker = makeAddr("taker");
    }

    // ==================== Build Tests ====================

    function test_Build_MinimalArgs() public view {
        bytes memory packed = TakerTraitsLib.build(_defaultArgs());

        assertTrue(packed.length >= 22, "Packed data should be at least 22 bytes");

        (TakerTraits traits,) = harness.parse(packed);
        assertTrue(traits.isExactIn());
        assertFalse(traits.shouldUnwrapWeth());
        assertFalse(traits.isStrictThresholdAmount());
    }

    function test_Build_WithThreshold() public view {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.threshold = abi.encodePacked(uint256(100e18));

        bytes memory packed = TakerTraitsLib.build(args);

        (bool hasThreshold, uint256 thresholdAmount) = harness.threshold(packed);
        assertTrue(hasThreshold);
        assertEq(thresholdAmount, 100e18);
    }

    function test_Build_WithTo() public {
        address recipient = makeAddr("recipient");
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.to = recipient;

        bytes memory packed = TakerTraitsLib.build(args);

        address extractedTo = harness.to(packed, taker);
        assertEq(extractedTo, recipient);
    }

    function test_Build_WithToSameAsTaker_NotIncluded() public view {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.to = taker; // Same as taker, should not be included

        bytes memory packed = TakerTraitsLib.build(args);

        address extractedTo = harness.to(packed, taker);
        assertEq(extractedTo, taker);
    }

    function test_Build_WithDeadline() public view {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.deadline = uint40(block.timestamp + 3600);

        bytes memory packed = TakerTraitsLib.build(args);

        uint40 extractedDeadline = harness.deadline(packed);
        assertEq(extractedDeadline, uint40(block.timestamp + 3600));
    }

    function test_Build_NoDeadline_ReturnsZero() public view {
        bytes memory packed = TakerTraitsLib.build(_defaultArgs());

        uint40 extractedDeadline = harness.deadline(packed);
        assertEq(extractedDeadline, 0);
    }

    function test_Build_Fuzz(
        bool isExactIn,
        bool shouldUnwrap,
        bool isStrict,
        bool isFirstFromTaker
    ) public view {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.isExactIn = isExactIn;
        args.shouldUnwrapWeth = shouldUnwrap;
        args.isStrictThresholdAmount = isStrict;
        args.isFirstTransferFromTaker = isFirstFromTaker;

        bytes memory packed = TakerTraitsLib.build(args);

        (TakerTraits traits,) = harness.parse(packed);
        assertEq(traits.isExactIn(), isExactIn);
        assertEq(traits.shouldUnwrapWeth(), shouldUnwrap);
        assertEq(traits.isStrictThresholdAmount(), isStrict);
        assertEq(traits.isFirstTransferFromTaker(), isFirstFromTaker);
    }

    // ==================== Validate Tests ====================

    function test_Validate_AmountOutZero_Reverts() public {
        bytes memory packed = TakerTraitsLib.build(_defaultArgs());

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector,
            0
        ));
        harness.validate(packed, 1e18, 1e18, 0);
    }

    function test_Validate_DeadlineExpired_Reverts() public {
        vm.warp(1700000000);

        TakerTraitsLib.Args memory args = _defaultArgs();
        args.deadline = uint40(block.timestamp - 1);
        bytes memory packed = TakerTraitsLib.build(args);

        vm.expectRevert(TakerTraitsLib.TakerTraitsDeadlineExpired.selector);
        harness.validate(packed, 1e18, 1e18, 1e18);
    }

    function test_Validate_ExactIn_TakerAmountMismatch_Reverts() public {
        bytes memory packed = TakerTraitsLib.build(_defaultArgs());

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector,
            2e18,
            1e18
        ));
        harness.validate(packed, 2e18, 1e18, 1e18);
    }

    function test_Validate_ExactIn_ThresholdNotMet_Reverts() public {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.threshold = abi.encodePacked(uint256(25e18));
        bytes memory packed = TakerTraitsLib.build(args);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector,
            20e18,
            25e18
        ));
        harness.validate(packed, 1e18, 1e18, 20e18);
    }

    function test_Validate_ExactIn_StrictThresholdMismatch_Reverts() public {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.isStrictThresholdAmount = true;
        args.threshold = abi.encodePacked(uint256(25e18));
        bytes memory packed = TakerTraitsLib.build(args);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsNonExactThresholdAmountOut.selector,
            30e18,
            25e18
        ));
        harness.validate(packed, 1e18, 1e18, 30e18);
    }

    function test_Validate_ExactOut_TakerAmountMismatch_Reverts() public {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.isExactIn = false;
        bytes memory packed = TakerTraitsLib.build(args);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector,
            2e18,
            1e18
        ));
        harness.validate(packed, 2e18, 1e18, 1e18);
    }

    function test_Validate_ExactOut_ThresholdExceeded_Reverts() public {
        TakerTraitsLib.Args memory args = _defaultArgs();
        args.isExactIn = false;
        args.threshold = abi.encodePacked(uint256(40e18));
        bytes memory packed = TakerTraitsLib.build(args);

        vm.expectRevert(abi.encodeWithSelector(
            TakerTraitsLib.TakerTraitsExceedingMaxInputAmount.selector,
            50e18,
            40e18
        ));
        harness.validate(packed, 25e18, 50e18, 25e18);
    }

    function test_Validate_Success() public view {
        bytes memory packed = TakerTraitsLib.build(_defaultArgs());

        // Should not revert
        harness.validate(packed, 1e18, 1e18, 1e18);
    }

    // ==================== Helper Functions ====================

    function _defaultArgs() internal view returns (TakerTraitsLib.Args memory) {
        return TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
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
            signature: ""
        });
    }
}
