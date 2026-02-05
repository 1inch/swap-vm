// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for L-1 audit finding: Fee does not enforce feeBps <= BPS at runtime for flat fees
// Location: Fee.sol - parseFlatFee() has no bounds check
// When feeBps > BPS (e.g., 2e9), the fee subtraction underflows in ExactIn mode:
// feeAmountIn = ctx.swap.amountIn * feeBps / BPS > ctx.swap.amountIn
// ctx.swap.amountIn -= feeAmountIn → UNDERFLOW
// </ai_context>

/// @title L-1 Audit Finding Test: Fee does not enforce feeBps <= BPS at runtime
/// @notice This test demonstrates that an order with feeBps > BPS (over 100% fee) will:
///         1. PANIC with arithmetic underflow in ExactIn mode (fee exceeds input)
///         2. Work in ExactOut mode but produce nonsensical results
/// @dev Finding location: Fee.sol - parseFlatFee() lacks runtime bounds check
///      feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
///      ctx.swap.amountIn -= feeAmountIn;  // Underflows when feeAmountIn > amountIn

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
import { Fee, FeeArgsBuilder, BPS } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract L1_Fee_NoBoundsCheckAtRuntime_Test is Test, OpcodesDebug {
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
    /// @dev Directly encodes feeBps without FeeArgsBuilder.buildFlatFee() validation
    function _buildFeeArgsRaw(uint32 feeBps) internal pure returns (bytes memory) {
        return abi.encodePacked(feeBps);
    }

    function _callBuildFlatFee(uint32 feeBps) external pure returns (bytes memory) {
        return FeeArgsBuilder.buildFlatFee(feeBps);
    }

    /// @notice Creates an order with feeBps > BPS (over 100% fee)
    function _createOrderWithOverflowFee(uint32 feeBps) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

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
                // Fee with > 100% (feeBps > BPS)
                program.build(Fee._flatFeeAmountInXD, _buildFeeArgsRaw(feeBps)),
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

    /// @notice MAIN TEST: feeBps > BPS causes arithmetic underflow
    /// @dev Fee._feeAmountIn has no bounds check, so feeAmountIn > amountIn causes underflow
    function test_L1_FeeBpsGreaterThanBPS_ExactIn_Underflow() public {
        uint32 feeBps = uint32(BPS * 2);  // 200% fee - clearly invalid!
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOverflowFee(feeBps);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // BUG: No bounds check in _feeAmountIn, so it underflows instead of proper error
        vm.expectRevert(stdError.arithmeticError);
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice Test with 150% fee - smaller overflow but still invalid
    function test_L1_FeeBps150Percent_ExactIn_Underflow() public {
        uint32 feeBps = uint32(BPS * 3 / 2);  // 150% fee
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOverflowFee(feeBps);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // BUG: No bounds check in _feeAmountIn, so it underflows instead of proper error
        vm.expectRevert(stdError.arithmeticError);
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice Test that feeBps just above BPS (100.0000001%) causes underflow
    function test_L1_FeeBpsJustAboveBPS_ExactIn_Underflow() public {
        uint32 feeBps = uint32(BPS + 1);  // 100.0000001% fee
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOverflowFee(feeBps);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // BUG: No bounds check in _feeAmountIn, so it underflows instead of proper error
        vm.expectRevert(stdError.arithmeticError);
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice Verify that FeeArgsBuilder.buildFlatFee rejects feeBps > BPS
    function test_L1_BuilderRejectsFeeBpsGreaterThanBPS() public {
        uint32 invalidFeeBps = uint32(BPS + 1);

        vm.expectRevert(abi.encodeWithSelector(FeeArgsBuilder.FeeBpsOutOfRange.selector, invalidFeeBps));
        this._callBuildFlatFee(invalidFeeBps);
    }

    /// @notice Verify that direct encoding bypasses builder validation
    function test_L1_DirectEncodingBypassesValidation() public pure {
        uint32 invalidFeeBps = uint32(BPS * 2);  // 200% fee

        // Direct encoding works (no validation)
        bytes memory args = abi.encodePacked(invalidFeeBps);
        assertEq(args.length, 4, "Args should be 4 bytes");

        // Decode to verify
        uint32 decoded = uint32(bytes4(args));
        assertEq(decoded, BPS * 2, "Should encode 200% fee");
    }

    /// @notice Test swap also fails with feeBps > BPS
    function test_L1_SwapFailsWithOverflowFee() public {
        uint32 feeBps = uint32(BPS * 2);  // 200% fee
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOverflowFee(feeBps);
        bytes memory exactInTakerData = _buildTakerData(true, signature);

        uint256 amountIn = 10e18;

        // BUG: No bounds check in _feeAmountIn, so it underflows instead of proper error
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice Test that valid fee (99%) works correctly
    function test_L1_ValidFee99PercentWorks() public {
        uint32 feeBps = uint32(BPS * 99 / 100);  // 99% fee - valid
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOverflowFee(feeBps);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // This should work - fee is valid
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }
}
