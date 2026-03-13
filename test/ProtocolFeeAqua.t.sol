// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS } from "../src/instructions/Fee.sol";
import { ContextLib } from "../src/libs/VM.sol";

contract ProtocolFeeAquaTest is AquaSwapVMTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function _makerSetup(
        uint32 feeInBps,
        uint32 protocolFeeBps
    ) internal view returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: INITIAL_BALANCE_A,
            balanceB: INITIAL_BALANCE_B,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: protocolFeeBps,
            feeInBps: feeInBps,
            protocolFeeRecipient: protocolFeeRecipient,
            swapType: SwapType.XYC
        });
    }

    function _swapProgram(
        uint256 amount,
        bool zeroForOne,
        bool isExactIn
    ) internal view returns (SwapProgram memory) {
        return SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: zeroForOne,
            isExactIn: isExactIn
        });
    }

    function test_Aqua_ProtocolFee_ExactIn_ReceivedByRecipient() public {
        MakerSetup memory setup = _makerSetup(0, 0.10e9); // 0% fee in, 10% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        mintTokenInToMaker(swapProgram, 200e18);
        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 expectedProtocolFee = amountIn * setup.protocolFeeBps / BPS;
        uint256 effectiveAmountIn = amountIn - expectedProtocolFee;
        uint256 amountOutExpected = setup.balanceB * effectiveAmountIn / (setup.balanceA + effectiveAmountIn);
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn - expectedProtocolFee, "Maker balance A should increase by amountIn minus protocol fee");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, expectedProtocolFee, "Protocol recipient received protocol fee in tokenIn");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, 0, "Protocol recipient balance B should not change");
    }

    function test_Aqua_ProtocolFee_ExactOut_ReceivedByRecipient() public {
        MakerSetup memory setup = _makerSetup(0, 0.10e9); // 0% fee in, 10% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB from tokenA

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        mintTokenInToMaker(swapProgram, 200e18);
        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 amountInBase = setup.balanceA * amountOut / (setup.balanceB - amountOut);
        uint256 expectedProtocolFee = amountInBase * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 amountInExpected = amountInBase + expectedProtocolFee;
        assertApproxEqAbs(takerBalanceABefore - takerBalanceAAfter, amountInExpected, 1, "Taker paid correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn - expectedProtocolFee, "Maker balance A should increase by amountIn minus protocol fee");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, expectedProtocolFee, "Protocol recipient received protocol fee in tokenIn");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, 0, "Protocol recipient balance B should not change");
    }

    function test_Aqua_ProtocolFee_ExactIn_WithFlatFeeIn() public {
        MakerSetup memory setup = _makerSetup(0.20e9, 0.05e9); // 20% fee in, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        mintTokenInToMaker(swapProgram, 200e18);
        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 protocolFee = amountIn * setup.protocolFeeBps / BPS;
        uint256 afterProtocolFee = amountIn - protocolFee;
        uint256 feeIn = afterProtocolFee * setup.feeInBps / BPS;
        uint256 effectiveAmountIn = afterProtocolFee - feeIn;
        uint256 amountOutExpected = setup.balanceB * effectiveAmountIn / (setup.balanceA + effectiveAmountIn);
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn - protocolFee, "Maker balance A should increase by amountIn minus protocol fee");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, protocolFee, "Protocol recipient received protocol fee in tokenIn");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, 0, "Protocol recipient balance B should not change");
    }

    function test_Aqua_ProtocolFee_ExactOut_WithFlatFeeIn() public {
        MakerSetup memory setup = _makerSetup(0.20e9, 0.05e9); // 20% fee in, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB from tokenA

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        mintTokenInToMaker(swapProgram, 200e18);
        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore,) = getProtocolRecipientBalances();

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter,) = getProtocolRecipientBalances();

        uint256 protocolFee = protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore;
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn - protocolFee, "Maker balance A should increase by amountIn minus protocol fee");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertGt(protocolFee, 0, "Protocol fee should be non-zero");
    }

    function test_Aqua_ProtocolFee_WithFlatFeeIn_Consistency() public {
        MakerSetup memory setup = _makerSetup(0.10e9, 0.05e9); // 10% fee in, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgramIn = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB
        SwapProgram memory swapProgramOut = _swapProgram(0, true, false); // Swap for equivalent tokenB from tokenA

        mintTokenInToTaker(swapProgramIn);
        (uint256 amountIn, uint256 amountOut) = quote(swapProgramIn, order);

        mintTokenInToTaker(swapProgramOut);
        swapProgramOut.amount = amountOut;
        (uint256 amountIn2, uint256 amountOut2) = quote(swapProgramOut, order);

        assertApproxEqAbs(amountIn, amountIn2, 2, "AmountIn should be consistent between exactIn and exactOut swaps");
        assertApproxEqAbs(amountOut, amountOut2, 2, "AmountOut should be consistent between exactIn and exactOut swaps");
    }
}
