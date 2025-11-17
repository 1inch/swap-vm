// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS } from "../src/instructions/Fee.sol";
import { ContextLib } from "../src/libs/VM.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";

contract FeeAquaTest is AquaSwapVMTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function _makerSetup(
        uint32 feeInBps,
        uint32 feeOutBps
    ) internal pure returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: INITIAL_BALANCE_A,
            balanceB: INITIAL_BALANCE_B,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: 0,
            feeInBps: feeInBps,
            feeOutBps: feeOutBps,
            progressiveFeeBps: 0,
            protocolFeeRecipient: address(0),
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

    function test_Aqua_FeeIn_ExactIn_BalanceAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0.10e9, 0); // 10% fee in, 0% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFee = amountIn * setup.feeInBps / BPS;
        uint256 amountOutExpected = setup.balanceB * (amountIn - expectedFee) / (setup.balanceA + amountIn - expectedFee);
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeIn_ExactOut_BalancesAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0.10e9, 0); // 10% fee in, 0% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFee = amountIn * setup.feeInBps / BPS;
        uint256 amountInExpected = setup.balanceA * amountOut / (setup.balanceB - amountOut) + expectedFee;
        assertApproxEqAbs(takerBalanceABefore - takerBalanceAAfter, amountInExpected, 1, "Taker paid correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeOut_ExactIn_BalancesAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0, 0.10e9); // 0% fee in, 10% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFee = amountOut * setup.feeOutBps / (BPS - setup.feeOutBps);
        uint256 amountOutExpected = setup.balanceB * amountIn / (setup.balanceA + amountIn) - expectedFee;
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeOut_ExactOut_BalancesAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0, 0.10e9); // 0% fee in, 10% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFee = amountOut * setup.feeOutBps / (BPS - setup.feeOutBps);
        uint256 amountOutGross = amountOut + expectedFee;
        uint256 amountInExpected = setup.balanceA * amountOutGross / (setup.balanceB - amountOutGross);
        assertApproxEqAbs(takerBalanceABefore - takerBalanceAAfter, amountInExpected, 1, "Taker paid correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeIn_FeeOut_ExactIn_AppliedSimultaniously_BalancesAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0.05e9, 0.05e9); // 5% fee in, 5% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFeeIn = amountIn * setup.feeInBps / BPS;
        uint256 expectedFeeOut = amountOut * setup.feeOutBps / (BPS - setup.feeOutBps);
        uint256 amountOutExpected = setup.balanceB * (amountIn - expectedFeeIn) / (setup.balanceA + amountIn - expectedFeeIn) - expectedFeeOut;
        assertEq(takerBalanceBAfter - takerBalanceBBefore, amountOutExpected, "Taker received correct amountOut");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeIn_FeeOut_ExactOut_AppliedSimultaniously_BalancesAfterSwap() public {
        MakerSetup memory setup = _makerSetup(0.05e9, 0.05e9); // 5% fee in, 5% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB

        (uint256 makerBalanceABefore, uint256 makerBalanceBBefore) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        (uint256 takerBalanceABefore, uint256 takerBalanceBBefore) = getTakerBalances(swapProgram.taker);

        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        (uint256 makerBalanceAAfter, uint256 makerBalanceBAfter) = getAquaBalances(strategyHash);
        (uint256 takerBalanceAAfter, uint256 takerBalanceBAfter) = getTakerBalances(swapProgram.taker);

        uint256 expectedFeeIn = amountIn * setup.feeInBps / BPS;
        uint256 expectedFeeOut = amountOut * setup.feeOutBps / (BPS - setup.feeOutBps);
        uint256 amountOutGross = amountOut + expectedFeeOut;
        uint256 amountInExpected = setup.balanceA * amountOutGross / (setup.balanceB - amountOutGross) + expectedFeeIn;
        assertApproxEqAbs(takerBalanceABefore - takerBalanceAAfter, amountInExpected, 1, "Taker paid correct amountIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn, "Maker balance A should increase by amountIn");
        assertEq(makerBalanceBAfter, makerBalanceBBefore - amountOut, "Maker balance B should decrease by amountOut");
        assertEq(takerBalanceAAfter, takerBalanceABefore - amountIn, "Taker balance A should decrease by amountIn");
        assertEq(takerBalanceBAfter, takerBalanceBBefore + amountOut, "Taker balance B should increase by amountOut");
    }

    function test_Aqua_FeeIn_ExactIn_100Percent_ShouldRevert() public {
        MakerSetup memory setup = _makerSetup(1e9, 0); // 100% fee in, 0% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        mintTokenInToTaker(swapProgram);
        mintTokenOutToMaker(swapProgram, 200e18);

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swap(swapProgram, order);
    }

    function test_Aqua_FeeOut_ExactIn_100Percent_ShouldRevert() public {
        MakerSetup memory setup = _makerSetup(0, 1e9); // 0% fee in, 100% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        mintTokenInToTaker(swapProgram);
        mintTokenOutToMaker(swapProgram, 200e18);

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swap(swapProgram, order);
    }

    function test_Aqua_FeeIn_ExactOut_100Percent_ShouldRevert() public {
        MakerSetup memory setup = _makerSetup(1e9, 0); // 100% fee in, 0% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB

        mintTokenInToTaker(swapProgram);
        mintTokenOutToMaker(swapProgram, 200e18);

        // impossible to pay 100% feeIn on exactOut swap
        vm.expectRevert();
        swap(swapProgram, order);
    }

    function test_Aqua_FeeOut_ExactOut_100Percent_InfiniteAmountIn() public {
        MakerSetup memory setup = _makerSetup(0, 1e9); // 0% fee in, 100% fee out
        ISwapVM.Order memory order = createStrategy(setup);
        shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, false); // Swap for 100 tokenB

        // expectedFeeOut = amountOut * feeOutBps / (BPS - feeOutBps) = amountOut * 1e9 / 0
        (address tokenIn, address tokenOut) = getTokenAddresses(swapProgram);

        vm.expectRevert();
        swapVM.quote(
            order,
            tokenIn,
            tokenOut,
            swapProgram.amount,
            abi.encodePacked(takerData(address(swapProgram.taker), swapProgram.isExactIn))
        );
    }
}
