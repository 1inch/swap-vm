// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { ISwapVM } from "../src/SwapVM.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract SwapVMAquaTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    function setUp() public override {
        super.setUp();

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(address(taker), 1000e18);
    }

    function test_Aqua_XYC_SimpleSwap() public {
        // Setup using the unified structure
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: 0,
            feeInBps: 0,
            feeOutBps: 0,
            progressiveFeeBps: 0,
            protocolFeeRecipient: address(0),
            swapType: SwapType.XYC
        });

        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // Swap tokenB (token1) for tokenA (token0); zeroForOne=false means token1->token0
            isExactIn: true
        });

        // Mint tokens to taker
        mintTokenInToTaker(swapProgram);
        mintTokenOutToMaker(swapProgram, setup.balanceA);

        // Perform swap
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        // Verify results - XYC formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
        uint256 expectedAmountOut = (50e18 * 100e18) / (200e18 + 50e18); // = 20e18
        assertEq(amountOut, expectedAmountOut, "Unexpected amountOut");
        assertEq(amountIn, 50e18, "Unexpected amountIn");
    }
}
