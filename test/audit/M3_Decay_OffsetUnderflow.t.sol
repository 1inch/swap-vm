// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for M-3 audit finding: Decay::_decayXD underflow when offset exceeds balance
// Location: Decay.sol:87
// If the decayed offset exceeds balanceOut, subtraction underflows causing panic
// </ai_context>

/// @title M-3 Audit Finding Test: Decay::_decayXD underflow when offset exceeds balance
/// @notice This test demonstrates that if the decayed offset exceeds balanceOut,
///         the subtraction underflows causing a panic.
/// @dev Finding location: Decay.sol:87
///      ctx.swap.balanceOut -= _offsets[ctx.query.orderHash][ctx.query.tokenOut][false].getOffset(period);
///      If offset > balanceOut → subtraction underflows → panic
///
///      KEY INSIGHT: With STATIC balances, the balance resets to initial value each call,
///      but the decay OFFSET persists and accumulates across swaps. This mismatch can
///      cause offset > balance → underflow!

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
import { Decay, DecayArgsBuilder } from "../../src/instructions/Decay.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "../../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract M3_Decay_OffsetUnderflow_Test is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint16 constant DECAY_PERIOD = 300; // 5 minutes

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup balances
        TokenMock(tokenA).mint(maker, 10_000_000e18);
        TokenMock(tokenB).mint(maker, 10_000_000e18);
        TokenMock(tokenA).mint(taker, 10_000_000e18);
        TokenMock(tokenB).mint(taker, 10_000_000e18);

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

    uint256 private _orderNonce = 0;

    /// @notice Creates order with STATIC balances + Decay
    /// @dev Static balances reset each call, but Decay offsets persist!
    ///      This mismatch is the key to triggering the underflow.
    function _createStaticDecayOrder(uint256 balanceA, uint256 balanceB)
        internal
        returns (ISwapVM.Order memory order, bytes memory signature)
    {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            // STATIC balances - resets to initial each call!
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([balanceA, balanceB])
                )),
            // Decay - offsets PERSIST across calls!
            p.build(Decay._decayXD, DecayArgsBuilder.build(DECAY_PERIOD)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, ControlsArgsBuilder.buildSalt(uint64(0x5000 + _orderNonce++)))
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

    /// @notice Creates order with DYNAMIC balances + Decay (normal usage)
    function _createDynamicDecayOrder(uint256 balanceA, uint256 balanceB)
        internal
        returns (ISwapVM.Order memory order, bytes memory signature)
    {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([tokenA, tokenB]),
                    dynamic([balanceA, balanceB])
                )),
            p.build(Decay._decayXD, DecayArgsBuilder.build(DECAY_PERIOD)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, ControlsArgsBuilder.buildSalt(uint64(0x5000 + _orderNonce++)))
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

    /// @notice MAIN TEST: Natural underflow with STATIC balances + Decay
    /// @dev The key insight: static balances RESET each call, but decay offsets ACCUMULATE.
    ///      Multiple swaps in same direction accumulate offset beyond the static balance.
    function test_M3_NaturalUnderflow_StaticBalancesWithDecay() public {
        // Order with STATIC balances (100, 100) + Decay
        // Static balances reset to (100, 100) on EACH call
        // But Decay offsets persist and accumulate!
        (ISwapVM.Order memory order, bytes memory signature) = _createStaticDecayOrder(100e18, 100e18);
        bytes memory takerData = _buildTakerData(true, signature);

        // ===== Swap 1: A→B with 80 =====
        // - Static balance sets A=100, B=100
        // - No decay offsets yet
        // - Swap proceeds: amountIn=80, amountOut≈44
        // - After: [A][false] offset = 80 (stored!)
        vm.prank(taker);
        (uint256 in1, uint256 out1,) = swapVM.swap(order, tokenA, tokenB, 80e18, takerData);
        emit log_named_uint("Swap 1 (A->B): amountIn", in1);
        emit log_named_uint("Swap 1 (A->B): amountOut", out1);

        // ===== Swap 2: A→B with 80 again =====
        // - Static balance RESETS to A=100, B=100
        // - [A][false] offset = 80 (still there, no decay yet)
        // - After adding this swap: [A][false] ≈ 80 + 80 = 160
        vm.prank(taker);
        (uint256 in2, uint256 out2,) = swapVM.swap(order, tokenA, tokenB, 80e18, takerData);
        emit log_named_uint("Swap 2 (A->B): amountIn", in2);
        emit log_named_uint("Swap 2 (A->B): amountOut", out2);

        // ===== Swap 3: B→A (reverse direction) =====
        // - Static balance RESETS to A=100, B=100
        // - Decay applies: balanceOut (A) -= [A][false] offset
        // - [A][false] ≈ 160e18 (accumulated from 2 swaps)
        // - balanceOut (A) = 100e18
        // - 100e18 - 160e18 = UNDERFLOW!

        emit log("Swap 3 (B->A): Expecting underflow...");
        emit log("  Static balanceA = 100e18");
        emit log("  Accumulated [A][false] offset ~= 160e18");
        emit log("  100e18 - 160e18 = UNDERFLOW!");

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, 50e18, takerData);
    }

    /// @notice Shows dynamic balances don't have this issue
    /// @dev With dynamic balances, balance grows alongside offset
    function test_M3_DynamicBalancesAreSafe() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createDynamicDecayOrder(100e18, 100e18);
        bytes memory takerData = _buildTakerData(true, signature);

        // Same sequence of swaps
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 80e18, takerData);

        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 80e18, takerData);

        // Reverse swap - should work because balance grew with offset
        vm.prank(taker);
        (, uint256 out3,) = swapVM.swap(order, tokenB, tokenA, 50e18, takerData);

        assertGt(out3, 0, "Reverse swap should succeed with dynamic balances");
        emit log_named_uint("Swap 3 (B->A) with dynamic balances: amountOut", out3);
    }

    /// @notice Shows the opaque panic error users would see (using actual contract)
    function test_M3_PanicInsteadOfCustomError() public {
        // Users see: Panic(0x11) instead of a clear error like:
        // DecayOffsetExceedsBalance(offset, balanceOut)
        // This is demonstrated by the main test which reverts with arithmeticError

        (ISwapVM.Order memory order, bytes memory signature) = _createStaticDecayOrder(100e18, 100e18);
        bytes memory takerData = _buildTakerData(true, signature);

        // Accumulate offset beyond balance
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 80e18, takerData);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 80e18, takerData);

        // This reverts with Panic(0x11) - not a custom error
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, 50e18, takerData);
    }

    /// @notice Documents the vulnerability
    function test_M3_DocumentedVulnerability() public pure {
        // VULNERABILITY at Decay.sol:87:
        // ctx.swap.balanceOut -= _offsets[...][tokenOut][false].getOffset(period);
        //
        // ROOT CAUSE:
        // - Static balances reset to initial value each call
        // - Decay offsets persist and accumulate across calls
        // - After N swaps in same direction: offset = N * amountIn
        // - But balance still = initial
        // - When offset > balance → UNDERFLOW
        //
        // RECOMMENDED FIX:
        // uint256 offsetOut = _offsets[...].getOffset(period);
        // ctx.swap.balanceOut = ctx.swap.balanceOut > offsetOut
        //     ? ctx.swap.balanceOut - offsetOut : 0;

        assertTrue(true, "Vulnerability documented");
    }
}