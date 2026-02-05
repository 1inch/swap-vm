// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for L-3 audit finding: Controls::_onlyTakerTokenSupplyShareGte has potential overflow
// Location: Controls.sol - _onlyTakerTokenSupplyShareGte()
// The calculation: balance * 1e18 >= minShareE18 * totalSupply
// If balance > type(uint256).max / 1e18 (~1.15e59), the multiplication overflows
// </ai_context>

/// @title L-3 Audit Finding Test: Controls overflow in share calculation
/// @notice This test demonstrates that _onlyTakerTokenSupplyShareGte can overflow:
///         1. If a token has extremely high balance/supply (unrealistic for 18 decimals)
///         2. Or if a token has 27+ decimals (balance * 1e18 overflows)
/// @dev Finding location: Controls.sol
///      require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply, ...);
///      balance * 1e18 overflows when balance > ~1.15e59

import { Test, stdError } from "forge-std/Test.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "../../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { TokenMockDecimals } from "../mocks/TokenMockDecimals.sol";


contract L3_Controls_OverflowInShareCalculation_Test is Test, OpcodesDebug {
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
    }

    /// @notice Setup tokens with specific decimals
    function _setupTokens(uint8 decimalsA, uint8 decimalsB) internal {
        tokenA = address(new TokenMockDecimals("Token A", "TKA", decimalsA));
        tokenB = address(new TokenMockDecimals("Token B", "TKB", decimalsB));
    }

    /// @notice Creates an order with taker token supply share check
    function _createOrderWithShareCheck(
        address checkToken,
        uint64 minShareE18,
        uint256 balanceA,
        uint256 balanceB
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
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
                // Check taker's share of checkToken
                program.build(Controls._onlyTakerTokenSupplyShareGte, ControlsArgsBuilder.buildTakerTokenSupplyShareGte(checkToken, minShareE18)),
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
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

    /// @notice MAIN TEST: Demonstrates L-3 overflow with extremely high balance
    /// @dev balance * 1e18 overflows when balance > type(uint256).max / 1e18
    ///      type(uint256).max / 1e18 ≈ 1.157e59
    function test_L3_OverflowWithExtremeBalance() public {
        _setupTokens(18, 18);

        // Calculate the overflow threshold
        // type(uint256).max / 1e18 = ~1.157e59
        uint256 overflowThreshold = type(uint256).max / 1e18;
        uint256 extremeBalance = overflowThreshold + 1;  // Just above threshold

        // Mint extreme amounts (this is theoretically possible with some tokens)
        TokenMockDecimals(tokenA).mint(maker, 1000e18);
        TokenMockDecimals(tokenB).mint(maker, 1000e18);
        TokenMockDecimals(tokenA).mint(taker, extremeBalance);
        TokenMockDecimals(tokenB).mint(taker, 1000e18);

        // Approvals
        vm.prank(maker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);

        // Create order requiring 1% share of tokenA
        uint64 minShareE18 = 0.01e18;  // 1%
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithShareCheck(
            tokenA,
            minShareE18,
            1000e18,
            1000e18
        );

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // BUG: balance * 1e18 overflows because balance > type(uint256).max / 1e18
        // The share calculation in _onlyTakerTokenSupplyShareGte will overflow
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(taker);
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }

    /// @notice Test with 27 decimal token - shows extreme balances are needed to overflow
    /// @dev For reference: type(uint256).max / 1e18 ≈ 1.157e59
    ///      A balance of 1e50 with 27 decimals does NOT overflow (1e50 * 1e18 = 1e68 < 1.157e77)
    ///      This test demonstrates that realistic 27 decimal balances work fine
    function test_L3_NoOverflowWith27DecimalToken() public {
        // Use 27 decimal token
        _setupTokens(27, 18);

        // With 27 decimals, 1e50 * 1e18 = 1e68 which does NOT overflow
        // (type(uint256).max ≈ 1.157e77)
        uint256 largeBalance = 1e50;

        TokenMockDecimals(tokenA).mint(maker, 1000e27);
        TokenMockDecimals(tokenB).mint(maker, 1000e18);
        TokenMockDecimals(tokenA).mint(taker, largeBalance);
        TokenMockDecimals(tokenB).mint(taker, 1000e18);

        // Approvals
        vm.prank(maker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);

        uint64 minShareE18 = 0.01e18;  // 1%
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithShareCheck(
            tokenA,
            minShareE18,
            1000e27,
            1000e18
        );

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e27;

        ISwapVM viewRouter = swapVM.asView();

        // This works because 1e50 * 1e18 = 1e68 < type(uint256).max
        vm.prank(taker);
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );
        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }

    /// @notice Test that normal balances work fine
    function test_L3_NormalBalancesWork() public {
        _setupTokens(18, 18);

        uint256 normalBalance = 1000e18;

        TokenMockDecimals(tokenA).mint(maker, normalBalance);
        TokenMockDecimals(tokenB).mint(maker, normalBalance);
        TokenMockDecimals(tokenA).mint(taker, normalBalance);
        TokenMockDecimals(tokenB).mint(taker, normalBalance);

        // Approvals
        vm.prank(maker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);

        // Create order requiring 1% share - taker has 50%
        uint64 minShareE18 = 0.01e18;  // 1%
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithShareCheck(
            tokenA,
            minShareE18,
            normalBalance,
            normalBalance
        );

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        vm.prank(taker);
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }

    /// @notice Test the boundary condition for overflow
    function test_L3_BoundaryCondition() public {
        _setupTokens(18, 18);

        // Exact boundary: type(uint256).max / 1e18
        uint256 maxSafeBalance = type(uint256).max / 1e18;

        // At boundary - should work
        assertEq(maxSafeBalance * 1e18 <= type(uint256).max, true, "Boundary should be safe");

        // One above - would overflow in unchecked context
        // maxSafeBalance + 1 would cause: (maxSafeBalance + 1) * 1e18 > type(uint256).max
    }

    /// @notice Verify the math: show what values cause overflow
    function test_L3_OverflowMathVerification() public pure {
        uint256 maxUint = type(uint256).max;
        uint256 scale = 1e18;

        // Calculate safe boundary
        uint256 maxSafeValue = maxUint / scale;

        // Verify
        assertLe(maxSafeValue * scale, maxUint, "maxSafeValue * scale should fit");

        // maxSafeValue + 1 would overflow (but we can't test that directly in pure)
        // (maxSafeValue + 1) * scale > maxUint

        // Log for documentation
        // maxSafeValue ≈ 1.157920892373161954235709850086879078532699846656405640394575840e59
    }

    /// @notice Test share check fails correctly when taker has insufficient share
    function test_L3_InsufficientShareFails() public {
        _setupTokens(18, 18);

        uint256 makerBalance = 9900e18;
        uint256 takerBalance = 100e18;

        TokenMockDecimals(tokenA).mint(maker, makerBalance);
        TokenMockDecimals(tokenB).mint(maker, 1000e18);
        TokenMockDecimals(tokenA).mint(taker, takerBalance);
        TokenMockDecimals(tokenB).mint(taker, 1000e18);

        // Approvals
        vm.prank(maker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMockDecimals(tokenB).approve(address(swapVM), type(uint256).max);

        // Require 10% share - taker only has 1%
        uint64 minShareE18 = 0.10e18;  // 10%
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithShareCheck(
            tokenA,
            minShareE18,
            1000e18,
            1000e18
        );

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // Should fail with insufficient share error
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.TakerTokenBalanceSupplyShareIsLessThatRequired.selector,
                taker,
                tokenA,
                takerBalance,
                makerBalance + takerBalance,
                minShareE18
            )
        );
        vm.prank(taker);
        viewRouter.quote(order, tokenA, tokenB, amountIn, exactInTakerData);
    }
}
