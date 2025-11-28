// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { ISwapVM } from "../src/SwapVM.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { MockTakerFirstTransfer } from "./mocks/MockTakerFirstTransfer.sol";

contract SwapVMAquaTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    function setUp() public override {
        super.setUp();
    }

    function _makerSetup() internal pure returns (MakerSetup memory) {
        return MakerSetup({
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
    }

    function test_Aqua_XYC_SimpleSwap() public {
        // Setup using the unified structure
        MakerSetup memory setup = _makerSetup();

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

    function test_Aqua_XYC_SwapWithFirstTransferFromTaker() public {
        // Create MockTakerFirstTransfer instance
        MockTakerFirstTransfer takerFirstTransfer = new MockTakerFirstTransfer(aqua, swapVM, address(this));

        // Setup using the unified structure
        MakerSetup memory setup = _makerSetup();

        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        SwapProgram memory swapProgram = SwapProgram({
            amount: 50e18,
            taker: takerFirstTransfer,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: false,  // Swap tokenB for tokenA
            isExactIn: true
        });

        // Mint tokens to takerFirstTransfer (tokenB)
        mintTokenInToTaker(swapProgram);
        // Mint tokens to takerFirstTransfer (tokenA) - needed for the preTransferInCallback
        // We need to mint exactly the amount that will be transferred to maker (20e18)
        uint256 expectedAmountOut = (50e18 * 100e18) / (200e18 + 50e18); // = 20e18
        tokenA.mint(address(takerFirstTransfer), expectedAmountOut);

        // Create custom taker data with isFirstTransferFromTaker = true
        bytes memory customTakerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(swapProgram.taker),
            isExactIn: swapProgram.isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,  // This flag ensures tokens are first sent from taker
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));

        bytes memory sigAndTakerData = abi.encodePacked(customTakerData);
        (address tokenIn, address tokenOut) = getTokenAddresses(swapProgram);

        // Perform swap with custom taker data
        (uint256 amountIn, uint256 amountOut) = swapProgram.taker.swap(
            order,
            tokenIn,
            tokenOut,
            swapProgram.amount,
            sigAndTakerData
        );

        // Verify results - XYC formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
        assertEq(amountOut, expectedAmountOut, "Unexpected amountOut with isFirstTransferFromTaker");
        assertEq(amountIn, 50e18, "Unexpected amountIn with isFirstTransferFromTaker");

        // Verify final balances
        // The taker first transfers tokenA to maker in preTransferInCallback, then receives it back from the swap
        // So final balance should be: initial (expectedAmountOut) - sent to maker (expectedAmountOut) + received from swap (expectedAmountOut) = expectedAmountOut
        (uint256 takerBalanceA, uint256 takerBalanceB) = getTakerBalances(takerFirstTransfer);
        assertEq(takerBalanceA, expectedAmountOut, "Taker should have received tokenA");
        assertEq(takerBalanceB, 0, "Taker should have 0 tokenB remaining");
    }
}
