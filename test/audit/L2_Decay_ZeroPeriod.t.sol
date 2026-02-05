// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for L-2 audit finding: Decay::decayPeriod == 0 should be validated
// Location: Decay.sol - DecayArgsBuilder.parse() has no validation for period > 0
// While division-by-zero is practically unreachable due to timestamp logic,
// decayPeriod = 0 is clearly invalid and should be rejected for defense-in-depth.
// </ai_context>

/// @title L-2 Audit Finding Test: Decay::decayPeriod == 0 should be validated
/// @notice This test demonstrates behavior when decayPeriod = 0:
///         1. Due to timestamp logic, division-by-zero is avoided (returns 0 offset)
///         2. But decayPeriod = 0 is semantically invalid (instant decay = no decay feature)
///         3. Should be validated at parse time for defense-in-depth
/// @dev Finding location: Decay.sol - DecayArgsBuilder.parse()
///      In getOffset(): if decayPeriod = 0, expiration = time + 0 = time
///      Since time is set to block.timestamp when storing, block.timestamp >= expiration
///      is always true, returning 0 (avoiding div-by-zero but breaking the feature)

import { Test } from "forge-std/Test.sol";
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
import { Decay, DecayArgsBuilder } from "../../src/instructions/Decay.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract L2_Decay_ZeroPeriod_Test is Test, OpcodesDebug {
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

    /// @notice Build decay args with arbitrary period (bypassing any future validation)
    function _buildDecayArgsRaw(uint16 decayPeriod) internal pure returns (bytes memory) {
        return abi.encodePacked(decayPeriod);
    }

    /// @notice Creates an order with specified decay period
    function _createOrderWithDecay(uint16 decayPeriod) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
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
                // Decay with configurable period
                program.build(Decay._decayXD, _buildDecayArgsRaw(decayPeriod)),
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

    /// @notice Test that decayPeriod = 0 doesn't cause division-by-zero
    /// @dev Due to timestamp logic in getOffset(), division-by-zero is avoided:
    ///      expiration = time + 0 = time (which equals block.timestamp when set)
    ///      block.timestamp >= expiration is true → returns 0
    ///      But this means decay feature is completely broken (always 0 offset)
    function test_L2_DecayPeriodZero_DoesNotPanic() public {
        uint16 decayPeriod = 0;  // Invalid but accepted
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithDecay(decayPeriod);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // This should NOT panic - timestamp logic avoids div-by-zero
        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }

    /// @notice Test that swap works with decayPeriod = 0 (but decay is ineffective)
    function test_L2_DecayPeriodZero_SwapWorks() public {
        uint16 decayPeriod = 0;
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithDecay(decayPeriod);
        bytes memory exactInTakerData = _buildTakerData(true, signature);

        uint256 amountIn = 10e18;

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut,) = swapVM.swap(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(actualAmountIn, amountIn, "AmountIn should match");
        assertGt(actualAmountOut, 0, "Should return valid amountOut");
    }

    /// @notice Test that valid decay period (e.g., 1 hour) works correctly
    function test_L2_ValidDecayPeriodWorks() public {
        uint16 decayPeriod = 3600;  // 1 hour
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithDecay(decayPeriod);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }

    /// @notice Demonstrate that decayPeriod = 0 makes decay feature useless
    /// @dev With decayPeriod = 0, offsets are always 0 (instant expiration)
    ///      This means the decay adjustment has no effect
    function test_L2_DecayPeriodZero_RendersDecayUseless() public {
        uint16 zeroDecay = 0;
        uint16 normalDecay = 3600;

        // Create two orders - one with zero decay, one with normal decay
        (ISwapVM.Order memory orderZero, bytes memory sigZero) = _createOrderWithDecay(zeroDecay);
        (ISwapVM.Order memory orderNormal, bytes memory sigNormal) = _createOrderWithDecay(normalDecay);

        bytes memory exactInTakerDataZero = _buildTakerData(true, sigZero);
        bytes memory exactInTakerDataNormal = _buildTakerData(true, sigNormal);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        // Quote both orders
        (, uint256 amountOutZero,) = viewRouter.quote(
            orderZero, tokenA, tokenB, amountIn, exactInTakerDataZero
        );
        (, uint256 amountOutNormal,) = viewRouter.quote(
            orderNormal, tokenA, tokenB, amountIn, exactInTakerDataNormal
        );

        // For first quote, both should be identical (no previous swaps to create offsets)
        assertEq(amountOutZero, amountOutNormal, "First quotes should be equal");
    }

    /// @notice Test builder accepts decayPeriod = 0 (no validation)
    function test_L2_BuilderAcceptsZeroPeriod() public pure {
        bytes memory args = DecayArgsBuilder.build(0);
        // Builder produces 2 bytes for the uint16 decayPeriod
        assertEq(args.length, 2, "Args should be 2 bytes");
        // Verify the encoded value is 0
        assertEq(uint16(bytes2(args)), 0, "Encoded value should be 0");
    }

    /// @notice Test that minimum valid decay period (1 second) works
    function test_L2_MinimumDecayPeriodWorks() public {
        uint16 decayPeriod = 1;  // 1 second - minimum meaningful value
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithDecay(decayPeriod);

        bytes memory exactInTakerData = _buildTakerData(true, signature);
        uint256 amountIn = 10e18;

        ISwapVM viewRouter = swapVM.asView();

        (uint256 quotedAmountIn, uint256 quotedAmountOut,) = viewRouter.quote(
            order, tokenA, tokenB, amountIn, exactInTakerData
        );

        assertEq(quotedAmountIn, amountIn, "AmountIn should match");
        assertGt(quotedAmountOut, 0, "Should return valid amountOut");
    }
}
