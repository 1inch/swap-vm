// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { SwapVM } from "../src/SwapVM.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouterExperimental } from "../src/routers/AquaSwapVMRouterExperimental.sol";
import { BPS, Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { FeeExperimental } from "../src/instructions/FeeExperimental.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls } from "../src/instructions/Controls.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ContextLib } from "../src/libs/VM.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract ProtocolFeeExperimentalAquaTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    function setUp() public virtual override {
        super.setUp();
    }

    function _deployRouter() internal override returns (SwapVM) {
        return new AquaSwapVMRouterExperimental(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
    }

    function buildProgram(MakerSetup memory setup) internal view override returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory concentrateProgram = "";

        if(setup.swapType == SwapType.CONCENTRATE_GROW_LIQUIDITY ||
            setup.swapType == SwapType.CONCENTRATE_GROW_PRICE_RANGE) {
            uint256 sqrtPmin = Math.sqrt(setup.priceMin * 1e18);
            uint256 sqrtPmax = Math.sqrt(setup.priceMax * 1e18);
            concentrateProgram = p.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
            );
        }

        return bytes.concat(
            setup.protocolFeeBps > 0 ? p.build(FeeExperimental._aquaProtocolFeeAmountOutXD, FeeArgsBuilder.buildProtocolFee(setup.protocolFeeBps, setup.protocolFeeRecipient)) : bytes(""),
            concentrateProgram,
            setup.feeInBps > 0 ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(setup.feeInBps)) : bytes(""),
            setup.feeOutBps > 0 ? p.build(FeeExperimental._flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(setup.feeOutBps)) : bytes(""),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function _makerSetup(
        uint32 feeInBps,
        uint32 feeOutBps,
        uint32 protocolFeeBps
    ) internal view returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: INITIAL_BALANCE_A,
            balanceB: INITIAL_BALANCE_B,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: protocolFeeBps,
            feeInBps: feeInBps,
            feeOutBps: feeOutBps,
            progressiveFeeBps: 0,
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

    function test_Aqua_ProtocolFeeOut_ExactIn_ReceivedByRecipient() public {
        MakerSetup memory setup = _makerSetup(0, 0, 0.10e9); // 0% fee in, 0% fee out, 10% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 expectedProtocolFee = amountOut * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 amountOutExpected = setup.balanceB * amountIn / (setup.balanceA + amountIn) - expectedProtocolFee;
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut - expectedProtocolFee, "Maker balance B should decrease by amountOut + protocol fee");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, 0, "Protocol recipient balance A should not change");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, expectedProtocolFee, "Protocol recipient received correct protocol fee");
    }

    function test_Aqua_ProtocolFeeOut_ExactOut_ReceivedByRecipient() public {
        MakerSetup memory setup = _makerSetup(0, 0, 0.10e9); // 0% fee in, 0% fee out, 10% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB from tokenA

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 expectedProtocolFee = amountOut * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 amountInExpected = setup.balanceA * (amountOut + expectedProtocolFee) / (setup.balanceB - amountOut - expectedProtocolFee);
        assertApproxEqAbs(makerBalanceAAfter - makerBalanceABefore, amountInExpected, 1, "Maker received correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut - expectedProtocolFee, "Maker balance B should decrease by amountOut + protocol fee");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, 0, "Protocol recipient balance A should not change");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, expectedProtocolFee, "Protocol recipient received correct protocol fee");
    }

    function test_Aqua_ProtocolFeeOut_ExactIn_WithFlatFeeIn() public {
        MakerSetup memory setup = _makerSetup(0.20e9, 0, 0.05e9); // 20% fee in, 0% fee out, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBBefore) = getProtocolRecipientBalances();

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        uint256 feeIn = amountIn * setup.feeInBps / BPS;
        uint256 expectedProtocolFee = amountOut * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 amountOutExpected = setup.balanceB * (amountIn - feeIn) / (setup.balanceA + amountIn - feeIn) - expectedProtocolFee;
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut - expectedProtocolFee, "Maker balance B should decrease by amountOut + protocol fee");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, 0, "Protocol recipient balance A should not change");
        assertEq(protocolRecipientBalanceBAfter - protocolRecipientBalanceBBefore, expectedProtocolFee, "Protocol recipient received correct protocol fee");
    }

    function test_Aqua_ProtocolFeeOut_ExactOut_WithFlatFeeIn() public {
        MakerSetup memory setup = _makerSetup(0.20e9, 0, 0.05e9); // 20% fee in, 0% fee out, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB from tokenA

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceABefore, uint256 protocolRecipientBalanceBAfter) = getProtocolRecipientBalances();

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);
        (uint256 protocolRecipientBalanceAAfter, uint256 protocolRecipientBalanceBBAfter) = getProtocolRecipientBalances();

        uint256 expectedProtocolFee = amountOut * setup.protocolFeeBps / (BPS - setup.protocolFeeBps);
        uint256 amountOutGross = amountOut + expectedProtocolFee;
        uint256 amountInExpected = setup.balanceA * amountOutGross / (setup.balanceB - amountOutGross);
        uint256 feeIn = amountInExpected * setup.feeInBps / (BPS - setup.feeInBps);
        amountInExpected += feeIn;
        assertApproxEqAbs(makerBalanceAAfter - makerBalanceABefore, amountInExpected, 2, "Maker received correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut - expectedProtocolFee, "Maker balance B should decrease by amountOut + protocol fee");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
        assertEq(protocolRecipientBalanceAAfter - protocolRecipientBalanceABefore, 0, "Protocol recipient balance A should not change");
        assertEq(protocolRecipientBalanceBBAfter - protocolRecipientBalanceBAfter, expectedProtocolFee, "Protocol recipient received correct protocol fee");
    }

    function test_Aqua_ProtocolFeeOut_WithFlatFeeInAndOut_Consistency() public {
        MakerSetup memory setup = _makerSetup(0.10e9, 0.15e9, 0.05e9); // 10% fee in, 15% fee out, 5% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgramIn = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB
        SwapProgram memory swapProgramOut = _swapProgram(0, true, false); // Swap for equivalent tokenB from tokenA

        mintTokenInToTaker(swapProgramIn);
        mintTokenOutToMaker(swapProgramIn, 200e18);
        (uint256 amountIn, uint256 amountOut) = quote(swapProgramIn, order);

        mintTokenInToTaker(swapProgramOut);
        mintTokenOutToMaker(swapProgramOut, 200e18);
        swapProgramOut.amount = amountOut;
        (uint256 amountIn2, uint256 amountOut2) = quote(swapProgramOut, order);

        assertApproxEqAbs(amountIn, amountIn2, 2, "AmountIn should be consistent between exactIn and exactOut swaps");
        assertApproxEqAbs(amountOut, amountOut2, 2, "AmountOut should be consistent between exactIn and exactOut swaps");
    }
}
