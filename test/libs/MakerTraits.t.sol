// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { MakerTraits, MakerTraitsLib } from "../../src/libs/MakerTraits.sol";

/// @dev Harness to test internal functions via external calls
contract MakerTraitsHarness {
    using MakerTraitsLib for MakerTraits;

    function validate(uint256 traits, address tokenIn, address tokenOut, uint256 amountIn) external pure {
        MakerTraits.wrap(traits).validate(tokenIn, tokenOut, amountIn);
    }

    function program(uint256 traits, bytes calldata data) external pure returns (bytes calldata) {
        return MakerTraits.wrap(traits).program(data);
    }
}

/**
 * @title MakerTraitsFlagsTest
 * @notice Unit and fuzz tests for MakerTraits flag getters
 * @dev Tests all flag extraction functions with explicit and fuzz inputs
 */
contract MakerTraitsFlagsTest is Test {
    using MakerTraitsLib for MakerTraits;

    MakerTraitsHarness private harness;

    // ==================== Flag Bit Constants ====================

    uint256 private constant _SHOULD_UNWRAP_BIT_FLAG = 1 << 255;
    uint256 private constant _USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG = 1 << 254;
    uint256 private constant _ALLOW_ZERO_AMOUNT_IN = 1 << 253;
    uint256 private constant _HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG = 1 << 252;
    uint256 private constant _HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG = 1 << 251;
    uint256 private constant _HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG = 1 << 250;
    uint256 private constant _HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG = 1 << 249;
    uint256 private constant _PRE_TRANSFER_IN_HOOK_HAS_TARGET = 1 << 248;
    uint256 private constant _POST_TRANSFER_IN_HOOK_HAS_TARGET = 1 << 247;
    uint256 private constant _PRE_TRANSFER_OUT_HOOK_HAS_TARGET = 1 << 246;
    uint256 private constant _POST_TRANSFER_OUT_HOOK_HAS_TARGET = 1 << 245;

    function setUp() public {
        harness = new MakerTraitsHarness();
    }

    // ==================== shouldUnwrapWeth Flag Tests ====================

    function test_ShouldUnwrapWeth_True() public pure {
        assertTrue(MakerTraits.wrap(_SHOULD_UNWRAP_BIT_FLAG).shouldUnwrapWeth());
    }

    function test_ShouldUnwrapWeth_False() public pure {
        assertFalse(MakerTraits.wrap(0).shouldUnwrapWeth());
    }

    function test_ShouldUnwrapWeth_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _SHOULD_UNWRAP_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).shouldUnwrapWeth(), expected);
    }

    // ==================== useAquaInsteadOfSignature Flag Tests ====================

    function test_UseAquaInsteadOfSignature_True() public pure {
        assertTrue(MakerTraits.wrap(_USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG).useAquaInsteadOfSignature());
    }

    function test_UseAquaInsteadOfSignature_False() public pure {
        assertFalse(MakerTraits.wrap(0).useAquaInsteadOfSignature());
    }

    function test_UseAquaInsteadOfSignature_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).useAquaInsteadOfSignature(), expected);
    }

    // ==================== allowZeroAmountIn Flag Tests ====================

    function test_AllowZeroAmountIn_True() public pure {
        assertTrue(MakerTraits.wrap(_ALLOW_ZERO_AMOUNT_IN).allowZeroAmountIn());
    }

    function test_AllowZeroAmountIn_False() public pure {
        assertFalse(MakerTraits.wrap(0).allowZeroAmountIn());
    }

    function test_AllowZeroAmountIn_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _ALLOW_ZERO_AMOUNT_IN) != 0;
        assertEq(MakerTraits.wrap(rawTraits).allowZeroAmountIn(), expected);
    }

    // ==================== hasPreTransferInHook Flag Tests ====================

    function test_HasPreTransferInHook_True() public pure {
        assertTrue(MakerTraits.wrap(_HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG).hasPreTransferInHook());
    }

    function test_HasPreTransferInHook_False() public pure {
        assertFalse(MakerTraits.wrap(0).hasPreTransferInHook());
    }

    function test_HasPreTransferInHook_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).hasPreTransferInHook(), expected);
    }

    // ==================== hasPostTransferInHook Flag Tests ====================

    function test_HasPostTransferInHook_True() public pure {
        assertTrue(MakerTraits.wrap(_HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG).hasPostTransferInHook());
    }

    function test_HasPostTransferInHook_False() public pure {
        assertFalse(MakerTraits.wrap(0).hasPostTransferInHook());
    }

    function test_HasPostTransferInHook_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).hasPostTransferInHook(), expected);
    }

    // ==================== hasPreTransferOutHook Flag Tests ====================

    function test_HasPreTransferOutHook_True() public pure {
        assertTrue(MakerTraits.wrap(_HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG).hasPreTransferOutHook());
    }

    function test_HasPreTransferOutHook_False() public pure {
        assertFalse(MakerTraits.wrap(0).hasPreTransferOutHook());
    }

    function test_HasPreTransferOutHook_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).hasPreTransferOutHook(), expected);
    }

    // ==================== hasPostTransferOutHook Flag Tests ====================

    function test_HasPostTransferOutHook_True() public pure {
        assertTrue(MakerTraits.wrap(_HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG).hasPostTransferOutHook());
    }

    function test_HasPostTransferOutHook_False() public pure {
        assertFalse(MakerTraits.wrap(0).hasPostTransferOutHook());
    }

    function test_HasPostTransferOutHook_Fuzz(uint256 rawTraits) public pure {
        bool expected = (rawTraits & _HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG) != 0;
        assertEq(MakerTraits.wrap(rawTraits).hasPostTransferOutHook(), expected);
    }

    // ==================== receiver Tests ====================

    function test_Receiver_Zero_ReturnsMaker() public pure {
        address makerAddr = address(0x1234);
        assertEq(MakerTraits.wrap(0).receiver(makerAddr), makerAddr);
    }

    function test_Receiver_NonZero_ReturnsReceiver() public pure {
        address makerAddr = address(0x1234);
        address receiverAddr = address(0x5678);
        assertEq(MakerTraits.wrap(uint160(receiverAddr)).receiver(makerAddr), receiverAddr);
    }

    function test_Receiver_Fuzz(uint256 rawTraits, address makerAddr) public pure {
        address extractedReceiver = address(uint160(rawTraits));
        address expected = extractedReceiver == address(0) ? makerAddr : extractedReceiver;
        assertEq(MakerTraits.wrap(rawTraits).receiver(makerAddr), expected);
    }

    // ==================== Combined Flags Tests ====================

    function test_AllFlagsSet() public pure {
        uint256 allFlags = _SHOULD_UNWRAP_BIT_FLAG |
            _USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG |
            _ALLOW_ZERO_AMOUNT_IN |
            _HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG |
            _HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG |
            _HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG |
            _HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG;

        MakerTraits traits = MakerTraits.wrap(allFlags);

        assertTrue(traits.shouldUnwrapWeth());
        assertTrue(traits.useAquaInsteadOfSignature());
        assertTrue(traits.allowZeroAmountIn());
        assertTrue(traits.hasPreTransferInHook());
        assertTrue(traits.hasPostTransferInHook());
        assertTrue(traits.hasPreTransferOutHook());
        assertTrue(traits.hasPostTransferOutHook());
    }

    function test_NoFlagsSet() public pure {
        MakerTraits traits = MakerTraits.wrap(0);

        assertFalse(traits.shouldUnwrapWeth());
        assertFalse(traits.useAquaInsteadOfSignature());
        assertFalse(traits.allowZeroAmountIn());
        assertFalse(traits.hasPreTransferInHook());
        assertFalse(traits.hasPostTransferInHook());
        assertFalse(traits.hasPreTransferOutHook());
        assertFalse(traits.hasPostTransferOutHook());
    }

    function test_AllFlags_Fuzz(
        bool shouldUnwrap,
        bool useAqua,
        bool allowZero,
        bool hasPreIn,
        bool hasPostIn,
        bool hasPreOut,
        bool hasPostOut
    ) public pure {
        uint256 rawTraits = (shouldUnwrap ? _SHOULD_UNWRAP_BIT_FLAG : 0) |
            (useAqua ? _USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG : 0) |
            (allowZero ? _ALLOW_ZERO_AMOUNT_IN : 0) |
            (hasPreIn ? _HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG : 0) |
            (hasPostIn ? _HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG : 0) |
            (hasPreOut ? _HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG : 0) |
            (hasPostOut ? _HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG : 0);

        MakerTraits traits = MakerTraits.wrap(rawTraits);

        assertEq(traits.shouldUnwrapWeth(), shouldUnwrap);
        assertEq(traits.useAquaInsteadOfSignature(), useAqua);
        assertEq(traits.allowZeroAmountIn(), allowZero);
        assertEq(traits.hasPreTransferInHook(), hasPreIn);
        assertEq(traits.hasPostTransferInHook(), hasPostIn);
        assertEq(traits.hasPreTransferOutHook(), hasPreOut);
        assertEq(traits.hasPostTransferOutHook(), hasPostOut);
    }

    function test_FlagsAreIndependent_Fuzz(uint256 rawTraits) public pure {
        MakerTraits traits = MakerTraits.wrap(rawTraits);

        assertEq(traits.shouldUnwrapWeth(), (rawTraits & _SHOULD_UNWRAP_BIT_FLAG) != 0);
        assertEq(traits.useAquaInsteadOfSignature(), (rawTraits & _USE_AQUA_INSTEAD_OF_SIGNATURE_BIT_FLAG) != 0);
        assertEq(traits.allowZeroAmountIn(), (rawTraits & _ALLOW_ZERO_AMOUNT_IN) != 0);
        assertEq(traits.hasPreTransferInHook(), (rawTraits & _HAS_PRE_TRANSFER_IN_HOOK_BIT_FLAG) != 0);
        assertEq(traits.hasPostTransferInHook(), (rawTraits & _HAS_POST_TRANSFER_IN_HOOK_BIT_FLAG) != 0);
        assertEq(traits.hasPreTransferOutHook(), (rawTraits & _HAS_PRE_TRANSFER_OUT_HOOK_BIT_FLAG) != 0);
        assertEq(traits.hasPostTransferOutHook(), (rawTraits & _HAS_POST_TRANSFER_OUT_HOOK_BIT_FLAG) != 0);
    }

    // ==================== Validate Tests ====================

    function test_Validate_TokenInEqualsTokenOut_Reverts() public {
        address token = makeAddr("token");

        vm.expectRevert(MakerTraitsLib.MakerTraitsTokenInAndTokenOutMustBeDifferent.selector);
        harness.validate(0, token, token, 1e18);
    }

    function test_Validate_ZeroAmountIn_NotAllowed_Reverts() public {
        address tokenIn = makeAddr("tokenIn");
        address tokenOut = makeAddr("tokenOut");

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        harness.validate(0, tokenIn, tokenOut, 0);
    }

    function test_Validate_ZeroAmountIn_Allowed_Success() public view {
        harness.validate(_ALLOW_ZERO_AMOUNT_IN, address(0x1111), address(0x2222), 0);
    }

    function test_Validate_DifferentTokens_NonZeroAmount_Success() public view {
        harness.validate(0, address(0x1111), address(0x2222), 1e18);
    }

    function test_Validate_Fuzz(
        address tokenIn,
        address tokenOut,
        bool allowZero
    ) public view {
        vm.assume(tokenIn != tokenOut);
        vm.assume(tokenIn != address(0) && tokenOut != address(0));

        uint256 traits = allowZero ? _ALLOW_ZERO_AMOUNT_IN : 0;

        // Should pass with non-zero amount regardless of flag
        harness.validate(traits, tokenIn, tokenOut, 1e18);

        // Should pass with zero amount only if flag is set
        if (allowZero) {
            harness.validate(traits, tokenIn, tokenOut, 0);
        }
    }

    // ==================== Build Tests ====================

    function test_Build_MinimalOrder() public pure {
        address maker = address(0x1234);
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: hex"1234"
        }));

        assertEq(order.maker, maker);
        assertFalse(order.traits.shouldUnwrapWeth());
        assertFalse(order.traits.useAquaInsteadOfSignature());
        assertFalse(order.traits.allowZeroAmountIn());
        assertEq(order.traits.receiver(maker), maker);
    }

    function test_Build_AllFlagsSet() public pure {
        address maker = address(0x1234);
        address receiver = address(0x5678);

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: receiver,
            shouldUnwrapWeth: true,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: true,
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
            program: hex"1234"
        }));

        assertTrue(order.traits.shouldUnwrapWeth());
        assertTrue(order.traits.useAquaInsteadOfSignature());
        assertTrue(order.traits.allowZeroAmountIn());
        assertEq(order.traits.receiver(maker), receiver);
    }

    function test_Build_Fuzz(
        address maker,
        address receiver,
        bool shouldUnwrap,
        bool useAqua,
        bool allowZero
    ) public pure {
        vm.assume(maker != address(0));

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: receiver,
            shouldUnwrapWeth: shouldUnwrap,
            useAquaInsteadOfSignature: useAqua,
            allowZeroAmountIn: allowZero,
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
            program: hex"00"
        }));

        assertEq(order.maker, maker);
        assertEq(order.traits.shouldUnwrapWeth(), shouldUnwrap);
        assertEq(order.traits.useAquaInsteadOfSignature(), useAqua);
        assertEq(order.traits.allowZeroAmountIn(), allowZero);

        address expectedReceiver = receiver == address(0) ? maker : receiver;
        assertEq(order.traits.receiver(maker), expectedReceiver);
    }

}
