// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { Invalidators } from "../src/instructions/Invalidators.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";


/**
 * @title Invalidators
 * @notice Tests functionality of Invalidators instruction
 * @dev Tests order invalidation mechanisms to prevent replay attacks
 */
contract InvalidatorsTest is Test, OpcodesDebug {
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
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * @notice Helper function for executing swaps
     */
    function _executeSwap(
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order,
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount
        require(actualIn == amount, "Unexpected input amount consumed");

        return actualOut;
    }

    /**
     * Test bit invalidation - order can only be used once
     */
    function test_InvalidateBitSingleUse() public {
        uint32 bitIndex = 42;

        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.InvalidateBit,
                InvalidatorsArgsBuilder.buildInvalidateBit(bitIndex)),
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 200e18])),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // First swap should succeed
        uint256 amountOut = _executeSwap(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        assertGt(amountOut, 0, "First swap should succeed");

        // Second swap should fail - bit already set
        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );
    }

    /**
     * Test different bit indices don't interfere
     */
    function test_InvalidateBitDifferentIndices() public {
        // Create two orders with different bit indices
        uint32 bitIndex1 = 10;
        uint32 bitIndex2 = 20;

        Program program1;
        bytes memory bytecode1 = bytes.concat(
            program1.build(Opcode.InvalidateBit,
                InvalidatorsArgsBuilder.buildInvalidateBit(bitIndex1)),
            program1.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(50e18), 100e18])),
            program1.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        Program program2;
        bytes memory bytecode2 = bytes.concat(
            program2.build(Opcode.InvalidateBit,
                InvalidatorsArgsBuilder.buildInvalidateBit(bitIndex2)),
            program2.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(50e18), 100e18])),
            program2.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order1 = _createOrder(bytecode1);
        ISwapVM.Order memory order2 = _createOrder(bytecode2);

        bytes memory exactInData = _signAndPackTakerData(order1, true, 0);

        // Execute first order
        _executeSwap(order1, address(tokenA), address(tokenB), 1e18, exactInData);

        // Second order should still work (different bit)
        exactInData = _signAndPackTakerData(order2, true, 0);
        _executeSwap(order2, address(tokenA), address(tokenB), 1e18, exactInData);
    }

    /**
     * Test token input invalidation - partial fills
     */
    function test_InvalidateTokenInPartialFills() public {
        // Order with 10 tokenA available, but can be filled multiple times
        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(10e18), 20e18])),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(Opcode.InvalidateTokenIn)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // First partial fill - 3 tokenA
        _executeSwap(order, address(tokenA), address(tokenB), 3e18, exactInData);

        // Second partial fill - 4 tokenA
        _executeSwap(order, address(tokenA), address(tokenB), 4e18, exactInData);

        // Third partial fill - 3 tokenA (should work - total 10)
        _executeSwap(order, address(tokenA), address(tokenB), 3e18, exactInData);

        // Fourth fill should fail - would exceed balance
        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );
    }

    /**
     * Test token output invalidation
     */
    function test_InvalidateTokenOutPartialFills() public {
        // Order with 20 tokenB available for output
        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 20e18])),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(Opcode.InvalidateTokenOut)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Use exactOut to control output amounts precisely
        bytes memory exactOutData;

        // First fill - want 8 tokenB out
        exactOutData = _signAndPackTakerData(order, false, 40e18);
        (uint256 amountIn1,,) = swapVM.asView().quote(
            order,
            8e18,
            exactOutData
        );
        TokenMock(address(tokenA)).mint(taker, amountIn1);
        swapVM.swap(order, 8e18, exactOutData);

        // Second fill - want 7 tokenB out
        exactOutData = _signAndPackTakerData(order, false, 35e18);
        (uint256 amountIn2,,) = swapVM.asView().quote(
            order,
            7e18,
            exactOutData
        );
        TokenMock(address(tokenA)).mint(taker, amountIn2);
        swapVM.swap(order, 7e18, exactOutData);

        // Third fill - want 5 tokenB out (total 20)
        exactOutData = _signAndPackTakerData(order, false, 25e18);
        (uint256 amountIn3,,) = swapVM.asView().quote(
            order,
            5e18,
            exactOutData
        );
        TokenMock(address(tokenA)).mint(taker, amountIn3);
        swapVM.swap(order, 5e18, exactOutData);

        // Fourth fill should fail - would exceed output balance
        exactOutData = _signAndPackTakerData(order, false, 1e18);
        vm.expectRevert();
        swapVM.swap(order, 1e18, exactOutData);
    }

    /**
     * Test combined invalidators
     */
    function test_CombinedInvalidators() public {
        uint32 bitIndex = 100;

        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.InvalidateBit,
                InvalidatorsArgsBuilder.buildInvalidateBit(bitIndex)),
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 200e18])),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(Opcode.InvalidateTokenIn),
            program.build(Opcode.InvalidateTokenOut)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // First swap should succeed and set bit + track tokens
        _executeSwap(order, address(tokenA), address(tokenB), 1e18, exactInData);

        // Second swap should fail due to bit invalidation (even if tokens available)
        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );
    }

    /**
     * Test bit slot boundaries (256 bits per slot)
     */
    function test_InvalidateBitSlotBoundaries() public {
        // Test bits at slot boundaries
        uint32[] memory bitIndices = new uint32[](4);
        bitIndices[0] = 255;   // Last bit of first slot
        bitIndices[1] = 256;   // First bit of second slot
        bitIndices[2] = 511;   // Last bit of second slot
        bitIndices[3] = 512;   // First bit of third slot

        for (uint256 i = 0; i < bitIndices.length; i++) {
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit,
                    InvalidatorsArgsBuilder.buildInvalidateBit(bitIndices[i])),
                program.build(Opcode.StaticBalances,
                    BalancesArgsBuilder.build([uint256(10e18), 20e18])),
                program.build(Opcode.LimitSwap,
                    LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should work first time
            _executeSwap(order, address(tokenA), address(tokenB), 1e18, exactInData);

            // Should fail second time
            TokenMock(address(tokenA)).mint(taker, 1e18);
            vm.expectRevert();
            swapVM.swap(order, 1e18, exactInData);
        }
    }

    /**
     * Test external invalidation functions
     */
    function test_ExternalInvalidation() public {
        // Get invalidators contract address from SwapVM
        Invalidators invalidators = Invalidators(address(swapVM));

        // Pre-invalidate a bit as maker
        uint256 bitToInvalidate = 999;
        vm.prank(maker);
        invalidators.invalidateBit(bitToInvalidate);

        // Create order using that bit
        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.InvalidateBit,
                InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToInvalidate))),
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 200e18])),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Should fail - bit already invalidated
        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );

        // Order with token input tracking should fail immediately
        Program program2;
        bytes memory bytecode2 = bytes.concat(
            program2.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 200e18])),
            program2.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program2.build(Opcode.InvalidateTokenIn)
        );

        ISwapVM.Order memory order2 = _createOrder(bytecode2);
        bytes memory exactInData2 = _signAndPackTakerData(order2, true, 0);

        // Also test external token invalidation
        bytes32 orderHash = swapVM.hash(order2);
        vm.prank(maker);
        invalidators.invalidateTokenIn(orderHash, address(tokenA));

        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order2,
            1e18,
            exactInData2
        );
    }

    function test_ExternalInvalidationMultiBits() public {
        // Get invalidators contract address from SwapVM
        Invalidators invalidators = Invalidators(address(swapVM));

        // Pre-invalidate a bit as maker
        uint248 slot = 5;
        uint256 bitToInvalidate1 = (slot << 8) + 1;
        uint256 bitToKeep1 = (slot << 8) + 2;
        uint256 bitToInvalidate2 = (slot << 8) + 3;
        uint256 bitToKeep2 = (slot << 8) + 4;
        uint256 bitToInvalidate3 = (slot << 8) + 5;

        vm.prank(maker);
        invalidators.invalidateBit(bitToInvalidate1);
        vm.prank(maker);
        invalidators.invalidateBits(slot, 32 + 8);

        // Check that 3rd and 5th bits are invalidated in addition to 1st
        {
            // Create order using bitToInvalidate1
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToInvalidate1))),
                program.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(100e18), 200e18])),
                program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should fail - bit already invalidated
            TokenMock(address(tokenA)).mint(taker, 1e18);
            vm.expectRevert();
            swapVM.swap(order, 1e18, exactInData);
        }
        {
            // Create order using bitToInvalidate2
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToInvalidate2))),
                program.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(100e18), 200e18])),
                program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should fail - bit already invalidated
            TokenMock(address(tokenA)).mint(taker, 1e18);
            vm.expectRevert();
            swapVM.swap(order, 1e18, exactInData);
        }
        {
            // Create order using bitToInvalidate3
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToInvalidate3))),
                program.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(100e18), 200e18])),
                program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should fail - bit already invalidated
            TokenMock(address(tokenA)).mint(taker, 1e18);
            vm.expectRevert();
            swapVM.swap(order, 1e18, exactInData);
        }

        {
            // Create order using bitToKeep1
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToKeep1))),
                program.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(100e18), 200e18])),
                program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should succeed - bit not invalidated
            TokenMock(address(tokenA)).mint(taker, 1e18);
            swapVM.swap(order, 1e18, exactInData);
        }
        {
            // Create order using bitToKeep2
            Program program;
            bytes memory bytecode = bytes.concat(
                program.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(bitToKeep2))),
                program.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(100e18), 200e18])),
                program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);
            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Should succeed - bit not invalidated
            TokenMock(address(tokenA)).mint(taker, 1e18);
            swapVM.swap(order, 1e18, exactInData);
        }
    }

    /**
     * Test zero amount handling
     */
    function test_InvalidatorZeroAmount() public {
        Program program;
        bytes memory bytecode = bytes.concat(
            program.build(Opcode.StaticBalances,
                BalancesArgsBuilder.build([uint256(100e18), 0]) // Zero output balance
                ),
            program.build(Opcode.LimitSwap,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(Opcode.InvalidateTokenOut)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Should revert - can't swap with zero balance
        TokenMock(address(tokenA)).mint(taker, 1e18);
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            threshold: thresholdData,
            to: address(this),
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

        return abi.encodePacked(takerTraits);
    }
}
