// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for M-1 audit finding: Division-by-zero if feeBps == BPS in ExactOut fee calculation
// Location: Fee.sol:196
// When feeBps = BPS = 1e9, denominator = (1e9 - 1e9) = 0 → division by zero
// </ai_context>

/// @title M-1 Audit Finding Test: Division-by-zero if feeBps == BPS in ExactOut fee calculation
/// @notice This test demonstrates that an order with feeBps = BPS (100% fee) will:
///         1. Work in ExactIn mode (divides by BPS)
///         2. PANIC in ExactOut mode (divides by BPS - feeBps = 0)
/// @dev Finding location: Fee.sol:196
///      feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
///      When feeBps = BPS = 1e9, denominator = (1e9 - 1e9) = 0 → division by zero

import { Test, stdError } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Fee, BPS } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract M1_Fee_DivisionByZero_100PercentFee_Test is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup balances
        TokenMock(tokenA).mint(maker, 1_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000e18);

        // Approvals
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    /// @notice Build fee args with arbitrary feeBps (bypassing builder validation for testing)
    /// @dev FeeArgsBuilder.buildFlatFee() allows feeBps == BPS, but we encode directly
    function _buildFeeArgs(uint32 feeBps) internal pure returns (bytes memory) {
        return abi.encodePacked(feeBps);
    }

    /// @notice Creates an order with 100% fee (feeBps = BPS = 1e9)
    function _createOrderWith100PercentFee() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = uint32(BPS);  // 100% fee - this triggers the bug!

        Program memory program = ProgramBuilder.init(_opcodes());

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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
                // Fee with 100% (BPS = 1e9)
                program.build(Fee._flatFeeAmountInXD, _buildFeeArgs(feeBps)),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
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

    /// @notice Test ExactIn mode with 100% fee - reverts due to zero output validation
    /// @dev ExactIn uses: feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
    ///      With 100% fee, all input goes to fee so amountOut = 0, which is rejected.
    ///      This shows 100% fee breaks the order in ExactIn mode too (different error).
    function test_M1_ExactIn_AlsoFailsWith100PercentFee() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWith100PercentFee();

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // ExactIn fails because 100% fee results in 0 output which is rejected
        vm.expectRevert(abi.encodeWithSignature("TakerTraitsAmountOutMustBeGreaterThanZero(uint256)", 0));
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice MAIN TEST: Demonstrates the M-1 vulnerability in ExactOut mode (quote)
    /// @dev ExactOut PANICs because Fee.sol:196 divides by (BPS - feeBps):
    ///      feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
    ///      With feeBps = BPS: denominator = (1e9 - 1e9) = 0 → DIVISION BY ZERO
    function test_M1_DivisionByZero_100PercentFee_ExactOut_Quote() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWith100PercentFee();

        bytes memory exactOutTakerData = _buildTakerData(false, signature);
        uint256 amountOut = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // ExactOut should PANIC with division by zero
        vm.expectRevert(stdError.divisionError);
        viewRouter.quote(order, tokenA, tokenB, amountOut, exactOutTakerData);
    }

    /// @notice Test that swap also fails in ExactOut mode
    function test_M1_SwapFailsExactOut() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWith100PercentFee();
        bytes memory exactOutTakerData = _buildTakerData(false, signature);

        uint256 amountOut = 10e18;

        vm.expectRevert(stdError.divisionError);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountOut, exactOutTakerData);
    }

    /// @notice Test edge case: feeBps just below 100% should work
    function test_M1_FeeJustBelow100PercentWorks() public view {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = uint32(BPS - 1);  // 99.9999999% fee - just below the limit

        Program memory program = ProgramBuilder.init(_opcodes());

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
                program.build(Fee._flatFeeAmountInXD, _buildFeeArgs(feeBps)),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory exactOutTakerData = _buildTakerData(false, signature);

        uint256 amountOut = 1e15;  // Small amount to avoid other overflows

        // This should work (denominator = 1, not 0)
        (uint256 quotedAmountIn,,) = swapVM.asView().quote(
            order, tokenA, tokenB, amountOut, exactOutTakerData
        );

        // With 99.9999999% fee, amountIn should be very large
        assertGt(quotedAmountIn, 0, "Should return valid quote");
    }
}
