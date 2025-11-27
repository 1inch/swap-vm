// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";

import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { MockNFT } from "./mocks/MockNft.sol";


contract ControlsAquaTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    MockNFT public nftGate;

    function setUp() public override {
        super.setUp();

        // Deploy NFT gate
        nftGate = new MockNFT("NFT Gate", "NFTG");

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(address(taker), 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(address(taker));
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _createStrategyForDeadline(uint40 deadline) internal view returns (ISwapVM.Order memory) {
        // Build program with deadline check and XYC swap
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(Controls._deadline, ControlsArgsBuilder.buildDeadline(deadline)),
            program.build(XYCSwap._xycSwapXD),
            program.build(Controls._salt, abi.encodePacked(vm.randomUint())) // ensure unique order hash
        );

        // Create order using Aqua
        ISwapVM.Order memory order = createStrategy(bytecode);
        return order;
    }

    function test_DeadlineControl() public {
        // Set deadline to 100 seconds from now
        uint40 deadline = uint40(block.timestamp + 100);

        // Create order using Aqua
        ISwapVM.Order memory order = _createStrategyForDeadline(deadline);

        // Ship strategy to Aqua
        shipStrategy(order, tokenA, tokenB, 100e18, 100e18);

        // Execute swap before deadline (should succeed)
        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // swap B for A
            isExactIn: true
        });

        mintTokenInToTaker(swapProgram, 70e18);

        (uint256 amountIn1, uint256 amountOut1) = swap(swapProgram, order);

        // Verify first swap succeeded
        assertEq(amountIn1, 50e18, "First swap: incorrect amountIn");
        // For XYC swap with 100:100 ratio, output should be calculated based on XYC formula
        uint256 expectedOut1 = uint256(50e18) * uint256(100e18) / (uint256(100e18) + uint256(50e18)); // ~33.33e18
        assertEq(amountOut1, expectedOut1, "First swap: incorrect amountOut");

        // Try to execute after deadline (should revert)
        vm.warp(block.timestamp + 101); // Move time forward to exceed deadline

        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.DeadlineReached.selector,
                address(taker),
                deadline
            )
        );
        swap(swapProgram, order);

        // Verify final balances
        (uint256 takerBalanceA, uint256 takerBalanceB) = getTakerBalances(taker);
        assertEq(takerBalanceA, expectedOut1, "Taker should have received tokenA");
        // Initial 1000e18 + 70e18 (minted) - 50e18 (first swap) = 1020e18
        assertEq(takerBalanceB, 1020e18, "Taker should have 1020 tokenB");
    }

    function test_DeadlineAlreadyPassed() public {
        // Set deadline to a time in the past
        uint40 deadline = uint40(block.timestamp - 1);

        // Create order using Aqua
        ISwapVM.Order memory order = _createStrategyForDeadline(deadline);

        // Ship strategy to Aqua
        shipStrategy(order, tokenA, tokenB, 100e18, 100e18);

        // Prepare swap
        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // swap B for A
            isExactIn: true
        });

        mintTokenInToTaker(swapProgram);

        // Should revert immediately because deadline has already passed
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.DeadlineReached.selector,
                address(taker),
                deadline
            )
        );
        swap(swapProgram, order);
    }

    function _createStrategyForCheckNft() internal view returns (ISwapVM.Order memory) {
        // Build program with NFT gate check and XYC swap
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(Controls._onlyTakerTokenBalanceNonZero, ControlsArgsBuilder.buildTakerTokenBalanceNonZero(address(nftGate))),
            program.build(XYCSwap._xycSwapXD),
            program.build(Controls._salt, abi.encodePacked(vm.randomUint())) // ensure unique order hash
        );

        // Create order using Aqua
        ISwapVM.Order memory order = createStrategy(bytecode);
        return order;
    }

    function test_OnlyTakerTokenBalanceNonZero_Success() public {
        // Mint NFT to taker so it can pass the gate check
        nftGate.mint(address(taker));

        // Create order using Aqua
        ISwapVM.Order memory order = _createStrategyForCheckNft();

        // Ship strategy to Aqua
        shipStrategy(order, tokenA, tokenB, 100e18, 100e18);

        // Prepare swap
        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // swap B for A
            isExactIn: true
        });

        mintTokenInToTaker(swapProgram);

        // Execute swap - should succeed because taker has the NFT
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        // Verify swap succeeded
        assertEq(amountIn, 50e18, "Incorrect amountIn");
        uint256 expectedOut = uint256(50e18) * uint256(100e18) / (uint256(100e18) + uint256(50e18)); // ~33.33e18
        assertEq(amountOut, expectedOut, "Incorrect amountOut");

        // Verify token balances
        (uint256 takerBalanceA, uint256 takerBalanceB) = getTakerBalances(taker);
        assertEq(takerBalanceA, expectedOut, "Taker should have received tokenA");
        // Initial 1000e18 + 50e18 (minted) - 50e18 (swapped) = 1000e18
        assertEq(takerBalanceB, 1000e18, "Taker should have 1000 tokenB (initial balance)");

        // Verify NFT balance unchanged
        assertEq(nftGate.balanceOf(address(taker)), 1, "Taker should still have the NFT");
    }

    function test_OnlyTakerTokenBalanceNonZero_Fail() public {
        // DO NOT mint NFT to taker - it should fail the gate check

        // Create order using Aqua
        ISwapVM.Order memory order = _createStrategyForCheckNft();

        // Ship strategy to Aqua
        shipStrategy(order, tokenA, tokenB, 100e18, 100e18);

        // Prepare swap
        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // swap B for A
            isExactIn: true
        });

        mintTokenInToTaker(swapProgram);

        // Execute swap - should fail because taker doesn't have the NFT
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.TakerTokenBalanceIsZero.selector,
                address(taker),
                address(nftGate)
            )
        );
        swap(swapProgram, order);

        // Verify NFT balance is zero
        assertEq(nftGate.balanceOf(address(taker)), 0, "Taker should not have the NFT");

        // Verify no tokens were transferred (taker still has initial tokens plus what we minted)
        (uint256 takerBalanceA, uint256 takerBalanceB) = getTakerBalances(taker);
        assertEq(takerBalanceA, 0, "Taker should have no tokenA");
        assertEq(takerBalanceB, 1050e18, "Taker should still have initial tokenB plus minted");
    }
}
