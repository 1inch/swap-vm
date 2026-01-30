// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for M-2 audit finding: Division-by-zero if initialLiquidity == 0 in XYCConcentrate
// Location: XYCConcentrate.sol:113
// After first trade sets liquidity[orderHash] to non-zero, second trade divides by initialLiquidity=0
// </ai_context>

/// @title M-2 Audit Finding Test: Division-by-zero if initialLiquidity == 0 in XYCConcentrate
/// @notice This test demonstrates that an order with initialLiquidity = 0 will:
///         1. Succeed on first trade (currentLiquidity == 0 takes the first branch)
///         2. PANIC on second trade (currentLiquidity != 0, divides by initialLiquidity = 0)
/// @dev Finding: After first trade, _updateScales() sets liquidity[orderHash] to non-zero.
///      On second trade, concentratedBalance() divides by initialLiquidity which is 0.

import { Test, stdError } from "forge-std/Test.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract M2_XYCConcentrate_ZeroInitialLiquidity_Test is Test, OpcodesDebug {
    using SafeCast for uint256;
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

    /// @notice Build program args for XYCConcentrate with custom initialLiquidity
    /// @dev Replicates XYCConcentrateArgsBuilder.build2D but allows setting arbitrary liquidity
    function _buildConcentrateArgs(
        address _tokenA,
        address _tokenB,
        uint256 deltaA,
        uint256 deltaB,
        uint256 initialLiquidity  // Can be set to 0 to trigger the bug!
    ) internal pure returns (bytes memory) {
        (uint256 deltaLt, uint256 deltaGt) = _tokenA < _tokenB ? (deltaA, deltaB) : (deltaB, deltaA);
        return abi.encodePacked(deltaLt, deltaGt, initialLiquidity);
    }

    /// @notice Creates an order with ZERO initialLiquidity - this is the vulnerability
    function _createOrderWithZeroLiquidity() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 deltaA = 100e18;   // Some delta
        uint256 deltaB = 100e18;   // Some delta
        uint256 initialLiquidity = 0;  // BUG: Setting to 0 will cause division by zero on second trade!

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
                program.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, _buildConcentrateArgs(
                    tokenA, tokenB, deltaA, deltaB, initialLiquidity
                )),
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

    /// @notice MAIN TEST: Demonstrates the M-2 vulnerability
    /// @dev First trade succeeds, second trade PANICs with division by zero
    function test_M2_DivisionByZero_InitialLiquidityZero() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithZeroLiquidity();
        bytes memory takerData = _buildTakerData(true, signature);

        // ===== FIRST TRADE =====
        // This succeeds because currentLiquidity == 0 in storage
        // So concentratedBalance() returns: balance + delta (first branch)
        uint256 amountIn1 = 10e18;

        vm.prank(taker);
        (, uint256 amountOut1,) = swapVM.swap(order, tokenA, tokenB, amountIn1, takerData);

        // First trade succeeded
        assertGt(amountOut1, 0, "First trade should succeed and return tokens");

        // Verify that liquidity[orderHash] is now NON-ZERO after first trade
        bytes32 orderHash = swapVM.hash(order);
        uint256 storedLiquidity = swapVM.liquidity(orderHash);
        assertGt(storedLiquidity, 0, "Liquidity should be set after first trade");

        // ===== SECOND TRADE =====
        // This will PANIC because:
        // - currentLiquidity != 0 (was set by first trade)
        // - initialLiquidity == 0 (from program args)
        // - concentratedBalance() computes: balance + delta * currentLiquidity / initialLiquidity
        //                                  = balance + delta * X / 0  <-- DIVISION BY ZERO!

        uint256 amountIn2 = 5e18;

        // Expect panic (division by zero is panic code 0x12)
        vm.expectRevert(stdError.divisionError);

        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn2, takerData);
    }

    /// @notice Test that quote also fails on second call (same vulnerability path)
    function test_M2_QuoteAlsoFailsOnSecondCall() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithZeroLiquidity();
        bytes memory quoteData = _buildTakerData(true, ""); // Empty signature for quoting

        // First quote succeeds
        uint256 amountIn = 10e18;
        ISwapVM viewRouter = swapVM.asView();
        (, uint256 quotedAmountOut1,) = viewRouter.quote(order, tokenA, tokenB, amountIn, quoteData);
        assertGt(quotedAmountOut1, 0, "First quote should succeed");

        // Execute first trade to set liquidity storage
        bytes memory swapData = _buildTakerData(true, signature);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn, swapData);

        // Second quote should fail with division by zero
        vm.expectRevert(stdError.divisionError);
        viewRouter.quote(order, tokenA, tokenB, amountIn, quoteData);
    }

    /// @notice Verify that the order is permanently bricked after first trade
    function test_M2_OrderPermanentlyBricked() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithZeroLiquidity();
        bytes memory takerData = _buildTakerData(true, signature);

        // First trade succeeds
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);

        // Any subsequent trade in ANY direction fails
        vm.expectRevert(stdError.divisionError);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 1e18, takerData);

        vm.expectRevert(stdError.divisionError);
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, 1e18, takerData);
    }
}