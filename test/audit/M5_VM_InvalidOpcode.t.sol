// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for M-5 audit finding: Invalid opcode causes array out-of-bounds panic
// Location: VM.sol:105
// If opcode >= opcodes.length, array access panics
// </ai_context>

/// @title M-5 Audit Finding Test: Invalid opcode causes array out-of-bounds panic
/// @notice This test demonstrates that programs with invalid opcodes cause opaque
///         array out-of-bounds panics instead of clear custom errors.
/// @dev Finding location: VM.sol:105
///      ctx.vm.opcodes[opcode](ctx, args);
///      If opcode >= ctx.vm.opcodes.length, this causes an array index out-of-bounds panic.

import { Test, stdError } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract M5_VM_InvalidOpcode_Test is Test, OpcodesDebug {
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

    /// @notice Creates an order with an invalid opcode (255, which is way beyond valid opcodes)
    function _createOrderWithInvalidOpcode() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Program with invalid opcode 255 (max uint8), argsLength=0
        bytes memory invalidProgram = hex"FF00"; // opcode=255, argsLength=0

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
            program: invalidProgram
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice Creates an order with opcode just past the valid range
    function _createOrderWithOpcodeJustPastRange() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // The Opcodes contract has ~50 instructions (0-49)
        // Using opcode 60 should be invalid
        bytes memory invalidProgram = hex"3C00"; // opcode=60, argsLength=0

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
            program: invalidProgram
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice MAIN TEST: Invalid opcode (255) causes array out-of-bounds panic
    /// @dev The opcodes array has ~50 entries, so opcode 255 is way out of bounds
    function test_M5_InvalidOpcode255_CausesPanic() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithInvalidOpcode();
        bytes memory takerData = _buildTakerData(true, signature);

        // This should panic with array index out of bounds
        vm.expectRevert(stdError.indexOOBError);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    /// @notice Test: Opcode just past valid range also causes panic
    function test_M5_OpcodeJustPastRange_CausesPanic() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithOpcodeJustPastRange();
        bytes memory takerData = _buildTakerData(true, signature);

        // This should panic with array index out of bounds
        vm.expectRevert(stdError.indexOOBError);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    /// @notice Quote also fails with invalid opcode
    function test_M5_QuoteAlsoFailsWithInvalidOpcode() public {
        (ISwapVM.Order memory order,) = _createOrderWithInvalidOpcode();
        bytes memory quoteData = _buildTakerData(true, "");

        ISwapVM viewRouter = swapVM.asView();

        vm.expectRevert(stdError.indexOOBError);
        viewRouter.quote(order, tokenA, tokenB, 10e18, quoteData);
    }

    /// @notice Documents the vulnerability
    function test_M5_DocumentedVulnerability() public pure {
        // VULNERABILITY at VM.sol:105:
        //
        // ctx.vm.opcodes[opcode](ctx, args);
        //
        // If opcode >= ctx.vm.opcodes.length, this causes:
        // - Panic(0x32) - Array index out of bounds
        //
        // Users see an opaque error instead of:
        // - RunLoopInvalidOpcode(opcode, ctx.vm.opcodes.length)
        //
        // RECOMMENDED FIX:
        // require(opcode < ctx.vm.opcodes.length, RunLoopInvalidOpcode(opcode, ctx.vm.opcodes.length));
        // ctx.vm.opcodes[opcode](ctx, args);

        assertTrue(true, "Vulnerability documented");
    }
}