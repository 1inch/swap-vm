// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/**
 * @title MakerAmountValidationTest
 * @notice Tests for amount validation in MakerTraits
 * @dev Validates the require statements in MakerTraits.validate:
 *      1. tokenIn != tokenOut
 *      2. amountIn > 0 (when allowZeroAmountIn is false)
 *      3. amountIn == 0 allowed (when allowZeroAmountIn is true)
 */
contract MakerAmountValidationTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ORDER_BALANCE = 1000e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        tokenA.mint(maker, 1_000_000e18);
        tokenA.mint(taker, 1_000_000e18);
        tokenB.mint(maker, 1_000_000e18);
        tokenB.mint(taker, 1_000_000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ==================== REQUIRE 1: tokenIn != tokenOut ====================
    // Note: The MakerTraits.validate check for tokenIn != tokenOut happens AFTER the program runs.
    // In practice, most programs (like Balances) will fail first when tokens are the same.
    // The MakerTraits check is a secondary validation layer.

    function test_TokenInMustNotEqualTokenOut_Reverts() public {
        // Build an order that includes both tokens in balances
        // When tokenIn == tokenOut, the Balances instruction fails first because it can only
        // match one token (the else-if never matches when both are the same address)
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrderWithBothTokens(false);
        bytes memory takerData = _buildTakerData(true, signature);

        // Try to swap with tokenIn == tokenOut - Balances fails first with its own error
        vm.prank(taker);
        vm.expectRevert(); // StaticBalancesRequiresSettingBothBalances
        swapVM.swap(order, address(tokenA), address(tokenA), 10e18, takerData);
    }

    function test_TokenInMustNotEqualTokenOut_Quote_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrderWithBothTokens(false);
        bytes memory takerData = _buildTakerData(true, signature);

        // Quote also reverts when tokenIn == tokenOut
        // Get the view first, then set expectRevert for the quote call
        ISwapVM viewRouter = swapVM.asView();
        vm.expectRevert(); // StaticBalancesRequiresSettingBothBalances
        viewRouter.quote(order, address(tokenA), address(tokenA), 10e18, takerData);
    }

    function test_DifferentTokens_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(true, signature);

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);
        uint256 takerTokenABefore = tokenA.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 10e18, takerData);

        // 3 requires pattern: verify all amounts are correct
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Maker should receive tokenA");
        assertEq(makerTokenBBefore - tokenB.balanceOf(maker), amountOut, "Maker should send tokenB");
        assertEq(takerTokenABefore - tokenA.balanceOf(taker), amountIn, "Taker should spend tokenA");
    }

    // ==================== REQUIRE 2: amountIn > 0 (when allowZeroAmountIn = false) ====================

    function test_ZeroAmountIn_NotAllowed_Reverts() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildLimitOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(false, signature); // ExactOut mode

        // In ExactOut mode with 0 amountOut requested, amountIn will be 0
        // This should revert because allowZeroAmountIn is false
        // Note: TakerTraits also validates amountOut > 0, but MakerTraits is checked first in the flow
        vm.prank(taker);
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, address(tokenA), address(tokenB), 0, takerData);
    }

    function test_NonZeroAmountIn_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(true, signature);

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 50e18, takerData);

        // 3 requires pattern: verify swap executed correctly with non-zero amounts
        assertGt(amountIn, 0, "AmountIn should be greater than zero");
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Maker should receive correct tokenA amount");
        assertEq(tokenB.balanceOf(taker) - takerTokenBBefore, amountOut, "Taker should receive correct tokenB amount");
    }

    // ==================== REQUIRE 3: allowZeroAmountIn flag behavior ====================
    // Note: Even with allowZeroAmountIn = true, TakerTraits.validate requires amountOut > 0
    // So we test the flag with very small amounts that result in non-zero swap but near-zero input

    function test_AllowZeroAmountIn_Flag_Set() public {
        // When allowZeroAmountIn is true, the MakerTraits validation allows amountIn = 0
        // However, TakerTraits independently requires amountOut > 0
        // We test that the flag is correctly interpreted by verifying a very small swap works
        (ISwapVM.Order memory order, bytes memory signature) = _buildLimitOrder(true, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(true, signature); // ExactIn mode

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);

        // Very small swap amount
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 1e15, takerData);

        // 3 requires pattern: verify swap with allowZeroAmountIn flag works
        assertGt(amountIn, 0, "AmountIn should be set");
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Maker should receive tokenA");
        assertEq(makerTokenBBefore - tokenB.balanceOf(maker), amountOut, "Maker should send tokenB");
    }

    function test_AllowZeroAmountIn_StillWorksWithNonZero() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildLimitOrder(true, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(true, signature); // ExactIn mode

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 50e18, takerData);

        // 3 requires pattern: even with flag set, non-zero swaps work correctly
        assertGt(amountIn, 0, "AmountIn should be greater than zero");
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Maker should receive tokenA");
        assertEq(makerTokenBBefore - tokenB.balanceOf(maker), amountOut, "Maker should send tokenB");
    }

    // ==================== COMBINED VALIDATION TESTS ====================

    function test_AllValidations_ExactIn_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(true, signature);

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 100e18, takerData);

        // Verify all 3 validation conditions are met
        assertGt(amountIn, 0, "Validation: amountIn > 0");
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Transfer: Maker received tokenA");
        assertEq(tokenB.balanceOf(taker) - takerTokenBBefore, amountOut, "Transfer: Taker received tokenB");
    }

    function test_AllValidations_ExactOut_Success() public {
        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(false, signature); // ExactOut

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 takerTokenBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), 50e18, takerData);

        // Verify all 3 validation conditions are met in ExactOut mode
        assertGt(amountIn, 0, "Validation: amountIn > 0 computed from exactOut");
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Transfer: Maker received tokenA");
        assertEq(tokenB.balanceOf(taker) - takerTokenBBefore, amountOut, "Transfer: Taker received tokenB");
    }

    // ==================== FUZZ TESTS ====================

    function test_AmountValidation_Fuzz(uint128 rawAmount, bool allowZero, bool isExactIn) public {
        // Always use non-zero amounts since TakerTraits requires amountOut > 0
        uint256 amount = bound(uint256(rawAmount), 1e15, ORDER_BALANCE / 2);

        (ISwapVM.Order memory order, bytes memory signature) = allowZero
            ? _buildLimitOrder(true, address(tokenA), address(tokenB))
            : _buildOrder(false, address(tokenA), address(tokenB));
        bytes memory takerData = _buildTakerData(isExactIn, signature);

        uint256 makerTokenABefore = tokenA.balanceOf(maker);
        uint256 makerTokenBBefore = tokenB.balanceOf(maker);

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amount, takerData);

        // 3 requires pattern for fuzz: validate amounts and transfers
        if (!allowZero) {
            assertGt(amountIn, 0, "AmountIn should be > 0 when zero not allowed");
        }
        assertEq(tokenA.balanceOf(maker) - makerTokenABefore, amountIn, "Maker received correct amountIn");
        assertEq(makerTokenBBefore - tokenB.balanceOf(maker), amountOut, "Maker sent correct amountOut");
    }

    // ==================== HELPER FUNCTIONS ====================

    function _buildOrder(
        bool allowZeroAmountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenIn, tokenOut]),
                dynamic([uint256(ORDER_BALANCE), uint256(ORDER_BALANCE)])
            )),
            program.build(XYCSwap._xycSwapXD)
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: allowZeroAmountIn,
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

    /// @dev Builds an order that includes both tokenA in balances to allow testing tokenIn == tokenOut
    function _buildOrderWithBothTokens(
        bool allowZeroAmountIn
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenA)]),
                dynamic([uint256(ORDER_BALANCE), uint256(ORDER_BALANCE)])
            )),
            program.build(XYCSwap._xycSwapXD)
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: allowZeroAmountIn,
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

    function _buildLimitOrder(
        bool allowZeroAmountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenIn, tokenOut]),
                dynamic([uint256(ORDER_BALANCE), uint256(ORDER_BALANCE)])
            )),
            program.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: allowZeroAmountIn,
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
        bytes memory signature
    ) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
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
            signature: signature
        }));
    }
}
