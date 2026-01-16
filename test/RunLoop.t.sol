// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test, stdError } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { DecayArgsBuilder } from "../src/instructions/Decay.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { MinRateArgsBuilder } from "../src/instructions/MinRate.sol";
import { InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";
import { TWAPSwapArgsBuilder } from "../src/instructions/TWAPSwap.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { Context, SwapRegisters, ContextLib } from "../src/libs/VM.sol";
import { BestRouteSelector } from "./mocks/BestRouteSelector.sol";

/**
 * @title RunLoopTest
 * @notice Comprehensive tests for runLoop functionality
 * @dev Tests cover:
 *      - Error conditions and edge cases
 *      - Nested runLoop execution through instructions
 *      - Stress tests and extruction + runLoop scenarios
 */
contract RunLoopTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        tokenA.mint(taker, 10000e18);
        tokenB.mint(taker, 10000e18);

        // Approve SwapVM
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ============================================
    // Section 1: Error Conditions & Edge Cases
    // ============================================

    /**
     * @notice Test that program completes without infinite loops
     * @dev Tests that runLoop properly advances PC and terminates
     */
    function test_RunLoopTermination() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        // Create a valid program that properly terminates
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            // Multiple instructions to verify PC advances correctly
            program.build(_salt, ControlsArgsBuilder.buildSalt(uint64(1))),
            program.build(_salt, ControlsArgsBuilder.buildSalt(uint64(2))),
            // NestedRunLoop instruction
            program.build(_decayXD, DecayArgsBuilder.build(3600)),
            program.build(_xycSwapXD) // Terminal - computes amounts and stops
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        (uint256 amountIn, uint256 amountOut, ) = _executeSwap(order, 1e18);

        // If runLoop had infinite loop or didn't advance PC, this would timeout/fail
        assertGt(amountOut, 0, "Program should terminate properly");
        assertEq(amountIn, 1e18, "AmountIn should be correct");
    }

    /**
     * @notice Test empty program (length = 0)
     * @dev Empty program should revert as it cannot compute swap amounts
     */
    function test_EmptyProgram() public {
        bytes memory bytecode = "";

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order);

        // Empty program fails with RunLoopExcessiveCall(0, 0)
        vm.expectRevert(
            abi.encodeWithSelector(ContextLib.RunLoopExcessiveCall.selector, 0, 0)
        );
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);
    }

    /**
     * @notice Test program with single byte (incomplete instruction)
     */
    function test_SingleByteProgram() public {
        bytes memory bytecode = hex"01"; // Just an opcode, no args length

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order);

        // Should revert with panic due to array out-of-bounds (0x32)
        vm.expectRevert(stdError.indexOOBError);
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);
    }

    /**
     * @notice Test invalid opcode (out of opcodes array bounds)
     */
    function test_InvalidOpcode() public {
        // Manually construct bytecode with invalid opcode
        bytes memory bytecode = abi.encodePacked(
            uint8(200), // Invalid opcode
            uint8(0)    // Args length
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order);

        // Should revert with panic due to array out-of-bounds (0x32)
        vm.expectRevert(stdError.indexOOBError);
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);
    }

    // ============================================
    // Section 2: Nested RunLoop (via instructions)
    // ============================================

    /**
     * @notice Test deep nesting (6 levels): DynamicBalances → Decay → Fee → XYCConcentrate → MinRate → XYCSwap
     */
    function test_NestedRunLoop_Deep_SixLevels() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )), // Level 0: DynamicBalances → runLoop
            program.build(_decayXD, DecayArgsBuilder.build(3600)), // Level 1: Decay → runLoop
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(0.01e9)), // Level 2: Fee (1%) → runLoop
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), 50e18, 50e18, 100e18)), // Level 3: XYCConcentrate → runLoop
            program.build(_requireMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), uint64(0.8e9), uint64(1.2e9))), // Level 4: MinRate → runLoop
            program.build(_xycSwapXD) // Level 5: XYCSwap (terminal)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        (uint256 amountIn, uint256 amountOut, ) = _executeSwap(order, 1e18);

        assertGt(amountOut, 0, "6-level nested runLoop should work");
        assertEq(amountIn, 1e18, "AmountIn should be equal to input amount");
    }

    /**
     * @notice Test static context (quote mode) with nested runLoop
     */
    function test_NestedRunLoop_StaticContext() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(3600)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order);

        // Use quote instead of swap
        (uint256 amountIn, uint256 amountOut, ) = swapVM.quote(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            takerData
        );

        assertGt(amountOut, 0, "Quote with nested runLoop should work");
        assertEq(amountIn, 1e18, "AmountIn should be equal to input amount");
    }

    // ============================================
    // Section 4: Stress Tests
    // ============================================

    /**
     * @notice Test very long program (50+ instructions)
     */
    function test_VeryLongProgram() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode = program.build(_dynamicBalancesXD,
            BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([uint256(100e18), uint256(100e18)])
            ));

        // Add 20 salt instructions (harmless, just increase program length)
        for (uint64 i = 0; i < 20; i++) {
            bytecode = bytes.concat(bytecode,
                program.build(_salt, ControlsArgsBuilder.buildSalt(i)));
        }

        // Add nested runLoop chain
        bytecode = bytes.concat(
            bytecode,
            program.build(_decayXD, DecayArgsBuilder.build(3600)),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(0.01e9)),
            program.build(_xycSwapXD)
        );

        // Add more salts
        for (uint64 i = 20; i < 40; i++) {
            bytecode = bytes.concat(bytecode,
                program.build(_salt, ControlsArgsBuilder.buildSalt(i)));
        }

        ISwapVM.Order memory order = _createOrder(bytecode);
        (uint256 amountIn, uint256 amountOut, ) = _executeSwap(order, 1e18);

        assertGt(amountOut, 0, "Long program should execute");
        assertEq(amountIn, 1e18, "AmountIn should be equal to input amount");
    }

    /**
     * @notice  BestRouteSelector with different strategies
     * @dev Key insight: Same balances, DIFFERENT strategies
     */
    function test_BestRouteSelector_XYC_vs_Pegged() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        BestRouteSelector selector = new BestRouteSelector(address(aqua));

        // Strategy 1: XYC (constant product)
        bytes memory strategy1 = program.build(_xycSwapXD);

        // Strategy 2: Pegged (optimized for stable pairs)
        bytes memory strategy2 = program.build(_peggedSwapGrowPriceRange2D,
            PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                x0: 50e18,          // balanceIn
                y0: 50e18,          // balanceOut
                linearWidth: 0.02e9, // 2% width for stable pairs
                rateLt: 1,
                rateGt: 1
            })));

        // Pack strategies with lengths
        bytes memory selectorArgs = abi.encodePacked(
            address(selector),              // Extruction target
            uint8(2),                       // 2 strategies
            uint16(strategy1.length),       // Strategy 1 length
            strategy1,                      // Strategy 1 bytecode
            uint16(strategy2.length),       // Strategy 2 length
            strategy2                       // Strategy 2 bytecode
        );

        // Main program: Balances → BestRouteSelector
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_extruction, selectorArgs)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        (uint256 amountIn, uint256 amountOut, ) = _executeSwap(order, 1e18);

        // BestRouteSelector tried BOTH strategies on SAME balances:
        // - Strategy 1 (XYC): ~0.99e18 output
        // - Strategy 2 (Pegged): slightly different output
        // → Returns best result!
        assertEq(amountIn, 1e18, "AmountIn unchanged");
        assertGt(amountOut, 0.98e18, "Best strategy selected");
        assertLt(amountOut, 1e18, "Some slippage expected");
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: program
        }));
    }

    function _signAndPackTakerData(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: bytes(""),
            to: taker,
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

    function _executeSwap(ISwapVM.Order memory order, uint256 amount)
        internal
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)
    {
        bytes memory takerData = _signAndPackTakerData(order);
        return swapVM.swap(order, address(tokenA), address(tokenB), amount, takerData);
    }
}
