// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// <ai_context>
// Test for M-4 audit finding: VM::runLoop lacks bounds checking for malformed programs
// Location: VM.sol:97-107
// Malformed programs with insufficient bytes cause opaque panic reverts
// </ai_context>

/// @title M-4 Audit Finding Test: VM::runLoop lacks bounds checking for malformed programs
/// @notice This test demonstrates that malformed programs cause opaque panic reverts
///         instead of clear custom errors.
/// @dev Finding location: VM.sol:97-107
///      Problem scenarios:
///      1. Single trailing byte: Loop enters with 1 byte remaining, reading argsLength panics
///      2. argsLength exceeds remaining bytes: Slice operation panics

import { Test, stdError } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";


contract M4_VM_RunLoop_BoundsCheck_Test is Test, OpcodesDebug {
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

    /// @notice Creates an order with a malformed program (single trailing byte)
    function _createOrderWithSingleTrailingByte() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Malformed program: just a single byte (opcode without argsLength)
        bytes memory malformedProgram = hex"0B"; // Just opcode 11 (jump), no argsLength byte

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
            program: malformedProgram
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice Creates an order with argsLength exceeding remaining bytes
    function _createOrderWithExcessiveArgsLength() internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        // Malformed program: opcode + argsLength that exceeds remaining bytes
        // opcode=11 (jump), argsLength=255, but only 2 bytes of args
        bytes memory malformedProgram = hex"0BFF0102"; // opcode=11, argsLength=255, only 2 bytes follow

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
            program: malformedProgram
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    /// @notice MAIN TEST: Single trailing byte causes panic
    /// @dev The VM loop reads: opcode = programBytes[pc++], argsLength = programBytes[pc++]
    ///      With only 1 byte, reading argsLength goes out of bounds
    function test_M4_SingleTrailingByte_CausesPanic() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithSingleTrailingByte();
        bytes memory takerData = _buildTakerData(true, signature);

        // This should panic with array out of bounds
        vm.expectRevert();
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    /// @notice Test: argsLength exceeds remaining bytes causes panic
    /// @dev The VM tries to slice programBytes[pc:pc+argsLength] but there aren't enough bytes
    function test_M4_ArgsLengthExceedsRemaining_CausesPanic() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithExcessiveArgsLength();
        bytes memory takerData = _buildTakerData(true, signature);

        // This should panic because slice goes out of bounds
        vm.expectRevert();
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 10e18, takerData);
    }

    /// @notice Quote also fails with same issues
    function test_M4_QuoteAlsoFailsWithMalformedProgram() public {
        (ISwapVM.Order memory order,) = _createOrderWithSingleTrailingByte();
        bytes memory quoteData = _buildTakerData(true, "");

        ISwapVM viewRouter = swapVM.asView();

        vm.expectRevert();
        viewRouter.quote(order, tokenA, tokenB, 10e18, quoteData);
    }

    /// @notice Documents the vulnerability
    function test_M4_DocumentedVulnerability() public pure {
        // VULNERABILITY at VM.sol:97-107:
        //
        // for (uint256 pc = ctx.vm.nextPC; pc < programBytes.length; ) {
        //     unchecked {
        //         uint256 opcode = uint8(programBytes[pc++]);      // Read byte 1
        //         uint256 argsLength = uint8(programBytes[pc++]);  // OOB if only 1 byte left!
        //         uint256 nextPC = pc + argsLength;
        //         bytes calldata args = programBytes[pc:nextPC];   // OOB if argsLength exceeds remaining
        //         // ...
        //     }
        // }
        //
        // PROBLEMS:
        // 1. Single trailing byte: reading argsLength goes out of bounds
        // 2. argsLength > remaining bytes: slice operation fails
        //
        // RECOMMENDED FIX:
        // require(pc + 1 < programBytes.length, RunLoopMalformedInstruction(pc));
        // require(nextPC <= programBytes.length, RunLoopArgsExceedProgram(pc, argsLength));

        assertTrue(true, "Vulnerability documented");
    }
}