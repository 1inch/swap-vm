// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls } from "../src/instructions/Controls.sol";
import { ContextLib } from "../src/libs/VM.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract ProtocolFeeAquaTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

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

    /// @dev Concentrated pool with equal balances: P_spot = 1 regardless of tokenA/tokenB
    ///      address ordering, price range [0.25, 4] is symmetric around the spot.
    function _concentrateMakerSetup(uint32 protocolFeeBps) internal view returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: 1000e18,
            balanceB: 1000e18,
            priceMin: 0.25e18,
            priceMax: 4e18,
            protocolFeeBps: protocolFeeBps,
            feeInBps: 0,
            protocolFeeRecipient: protocolFeeRecipient,
            swapType: SwapType.CONCENTRATE_GROW_LIQUIDITY
        });
    }

    /// @dev Drives the pool to the range boundary by buying the entire tokenB balance,
    ///      leaving the strategy's Aqua accounting balance of tokenB at exactly zero.
    function _drainTokenBToRangeBoundary(ISwapVM.Order memory order, bytes32 strategyHash) internal {
        // Maker wallet holds plenty of both tokens, so wallet funds are never the
        // constraint — only the strategy's Aqua accounting balance matters below.
        tokenA.mint(maker, 1_000_000e18);
        tokenB.mint(maker, 1_000_000e18);

        tradeToZeroBalance(order, tokenB);

        (, uint256 aquaBalanceB) = getAquaBalances(strategyHash);
        assertEq(aquaBalanceB, 0, "tokenB should be fully drained to the range boundary");
    }

    /// @notice Control: without protocol fee the AMM math allows swapping back
    ///         from the range boundary (virtual reserves cover the zero real balance).
    function test_Aqua_Concentrate_SwapBackAtRangeBoundary_NoProtocolFee_Succeeds() public {
        MakerSetup memory setup = _concentrateMakerSetup(0);
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        _drainTokenBToRangeBoundary(order, strategyHash);

        // Swap back: tokenB (drained) -> tokenA
        SwapProgram memory backSwap = _swapProgram(10e18, false, true);
        mintTokenInToTaker(backSwap);

        (uint256 amountIn, uint256 amountOut) = swap(backSwap, order);

        assertEq(amountIn, backSwap.amount, "Swap back should consume the exact amountIn");
        assertGt(amountOut, 0, "Swap back should produce non-zero amountOut");
    }

    /// @notice With Aqua protocol fee the swap back from the range boundary succeeds:
    ///         fee charging is best-effort. The fee pull in tokenIn fails (the strategy's
    ///         tokenIn balance is drained to zero, and the pull happens before the taker
    ///         pushes tokenIn), so the fee is skipped with a FeeChargeFailed event and
    ///         the fee share remains in the maker's strategy balance.
    function test_Aqua_ProtocolFee_Concentrate_SwapBackAtRangeBoundary_Succeeds() public {
        MakerSetup memory setup = _concentrateMakerSetup(0.01e9); // 1% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        _drainTokenBToRangeBoundary(order, strategyHash);

        // Recipient already collected fees in tokenA during the drain — snapshot here
        (uint256 recipientBalanceABefore, uint256 recipientBalanceBBefore) = getProtocolRecipientBalances();

        // Swap back: tokenB (drained) -> tokenA
        SwapProgram memory backSwap = _swapProgram(10e18, false, true);
        mintTokenInToTaker(backSwap);

        // Quote agrees the swap back is possible (static context skips the fee pull)
        (, uint256 quotedAmountOut) = quote(backSwap, order);
        assertGt(quotedAmountOut, 0, "Quote for swap back should succeed");

        uint256 expectedFee = backSwap.amount * setup.protocolFeeBps / BPS;
        vm.expectEmit(address(swapVM));
        emit FeeChargeFailed(swapVM.hash(order), address(tokenB), expectedFee, protocolFeeRecipient);

        (uint256 amountIn, uint256 amountOut) = swap(backSwap, order);

        assertEq(amountIn, backSwap.amount, "Swap back should consume the exact amountIn");
        assertGt(amountOut, 0, "Swap back should produce non-zero amountOut");
        assertEq(amountOut, quotedAmountOut, "Swap should match quote (quote/swap parity)");

        // Fee was skipped: recipient got nothing, the full amountIn stayed in the strategy
        (uint256 recipientBalanceAAfter, uint256 recipientBalanceBAfter) = getProtocolRecipientBalances();
        assertEq(recipientBalanceAAfter, recipientBalanceABefore, "Recipient balance A should not change");
        assertEq(recipientBalanceBAfter, recipientBalanceBBefore, "Recipient should not receive the skipped fee");
        (, uint256 aquaBalanceBAfter) = getAquaBalances(strategyHash);
        assertEq(aquaBalanceBAfter, amountIn, "Full amountIn incl. fee share should stay in the strategy");
    }

    /// @dev Same as _drainTokenBToRangeBoundary, but drains with a real swap only —
    ///      no quote() involved: the taker is simply funded generously upfront.
    function _drainTokenBToRangeBoundaryViaSwap(ISwapVM.Order memory order, bytes32 strategyHash) internal {
        // Maker wallet holds plenty of both tokens, so wallet funds are never the
        // constraint — only the strategy's Aqua accounting balance matters below.
        tokenA.mint(maker, 1_000_000e18);
        tokenB.mint(maker, 1_000_000e18);

        (, uint256 aquaBalanceB) = getAquaBalances(strategyHash);
        SwapProgram memory drainSwap = _swapProgram(aquaBalanceB, true, false); // tokenA -> tokenB, exactOut full balance
        mintTokenInToTaker(drainSwap, 1_000_000e18);
        swap(drainSwap, order);

        (, uint256 aquaBalanceBAfter) = getAquaBalances(strategyHash);
        assertEq(aquaBalanceBAfter, 0, "tokenB should be fully drained to the range boundary");
    }

    /// @notice Control (swap-only, exactOut): without protocol fee the swap back from
    ///         the range boundary succeeds. No quote() is used anywhere in this test.
    function test_Aqua_Concentrate_SwapBackAtRangeBoundary_NoProtocolFee_ExactOut_Succeeds() public {
        MakerSetup memory setup = _concentrateMakerSetup(0);
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        _drainTokenBToRangeBoundaryViaSwap(order, strategyHash);

        // Swap back: tokenB (drained) -> tokenA, exactOut
        SwapProgram memory backSwap = _swapProgram(10e18, false, false);
        mintTokenInToTaker(backSwap, 1_000_000e18);

        (uint256 amountIn, uint256 amountOut) = swap(backSwap, order);

        assertEq(amountOut, backSwap.amount, "Swap back should produce the exact amountOut");
        assertGt(amountIn, 0, "Swap back should consume non-zero amountIn");
    }

    /// @notice Same as above in exactOut mode (swap-only, no quote() anywhere): the fee
    ///         pull in drained tokenIn fails, the fee is skipped and the swap succeeds.
    function test_Aqua_ProtocolFee_Concentrate_SwapBackAtRangeBoundary_ExactOut_Succeeds() public {
        MakerSetup memory setup = _concentrateMakerSetup(0.01e9); // 1% protocol fee
        ISwapVM.Order memory order = createStrategy(setup);
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);

        _drainTokenBToRangeBoundaryViaSwap(order, strategyHash);

        // Recipient already collected fees in tokenA during the drain — snapshot here
        (uint256 recipientBalanceABefore, uint256 recipientBalanceBBefore) = getProtocolRecipientBalances();

        // Swap back: tokenB (drained) -> tokenA, exactOut
        SwapProgram memory backSwap = _swapProgram(10e18, false, false);
        mintTokenInToTaker(backSwap, 1_000_000e18);

        // exactOut: the fee amount depends on the AMM-quoted amountIn, so only the
        // indexed fields (orderHash, token, recipient) and the emitter are asserted
        vm.expectEmit(true, true, true, false, address(swapVM));
        emit FeeChargeFailed(swapVM.hash(order), address(tokenB), 0, protocolFeeRecipient);

        (uint256 amountIn, uint256 amountOut) = swap(backSwap, order);

        assertEq(amountOut, backSwap.amount, "Swap back should produce the exact amountOut");
        assertGt(amountIn, 0, "Swap back should consume non-zero amountIn");

        // Fee was skipped: recipient got nothing, the full amountIn stayed in the strategy
        (uint256 recipientBalanceAAfter, uint256 recipientBalanceBAfter) = getProtocolRecipientBalances();
        assertEq(recipientBalanceAAfter, recipientBalanceABefore, "Recipient balance A should not change");
        assertEq(recipientBalanceBAfter, recipientBalanceBBefore, "Recipient should not receive the skipped fee");
        (, uint256 aquaBalanceBAfter) = getAquaBalances(strategyHash);
        assertEq(aquaBalanceBAfter, amountIn, "Full amountIn incl. fee share should stay in the strategy");
    }

    // ========== Aqua Dynamic Protocol Fee Tests ==========

    /// @dev Program for `_aquaDynamicProtocolFeeAmountInXD`: plain XYC swap over Aqua
    ///      balances with a dynamic (provider-driven) protocol fee on amountIn.
    function _xycDynamicFeeProgram(address feeProvider) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(Fee._aquaDynamicProtocolFeeAmountInXD, FeeArgsBuilder.buildDynamicProtocolFee(feeProvider)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    /// @dev Same as _xycDynamicFeeProgram but with concentrated liquidity, mirroring
    ///      _concentrateMakerSetup: price range [0.25, 4] symmetric around spot 1.
    function _concentrateDynamicFeeProgram(address feeProvider) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        uint256 sqrtPmin = Math.sqrt(0.25e18 * 1e18);
        uint256 sqrtPmax = Math.sqrt(4e18 * 1e18);
        return bytes.concat(
            p.build(Fee._aquaDynamicProtocolFeeAmountInXD, FeeArgsBuilder.buildDynamicProtocolFee(feeProvider)),
            p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    /// @notice Success path: the dynamic Aqua protocol fee is pulled from the maker's
    ///         strategy balance to the provider-defined recipient.
    function test_Aqua_DynamicProtocolFee_ExactIn_ReceivedByRecipient() public {
        ProtocolFeeProviderMock feeProvider = new ProtocolFeeProviderMock(0.10e9, protocolFeeRecipient, address(this));
        ISwapVM.Order memory order = createStrategy(_xycDynamicFeeProgram(address(feeProvider)));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, INITIAL_BALANCE_A, INITIAL_BALANCE_B);
        SwapProgram memory swapProgram = _swapProgram(100e18, true, true); // Swap 100 tokenA for tokenB

        (uint256 makerBalanceABefore,) = getAquaBalances(strategyHash);

        mintTokenInToTaker(swapProgram);
        mintTokenInToMaker(swapProgram, 200e18);
        mintTokenOutToMaker(swapProgram, 200e18);
        (uint256 recipientBalanceABefore,) = getProtocolRecipientBalances();

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        // exactIn: fee is computed on the taker-defined amountIn
        uint256 expectedFee = amountIn * 0.10e9 / BPS;
        (uint256 recipientBalanceAAfter,) = getProtocolRecipientBalances();
        (uint256 makerBalanceAAfter,) = getAquaBalances(strategyHash);

        assertGt(amountOut, 0, "Swap should produce non-zero amountOut");
        assertEq(recipientBalanceAAfter - recipientBalanceABefore, expectedFee, "Recipient should receive the dynamic protocol fee in tokenIn");
        assertEq(makerBalanceAAfter, makerBalanceABefore + amountIn - expectedFee, "Maker balance A should increase by amountIn minus protocol fee");
    }

    /// @notice Catch path: at the range boundary the dynamic Aqua fee pull in drained
    ///         tokenIn fails, the fee is skipped with FeeChargeFailed and the swap
    ///         proceeds — mirroring the static-fee boundary test.
    function test_Aqua_DynamicProtocolFee_Concentrate_SwapBackAtRangeBoundary_FeeSkipped() public {
        uint32 feeBps = 0.01e9; // 1% protocol fee
        ProtocolFeeProviderMock feeProvider = new ProtocolFeeProviderMock(feeBps, protocolFeeRecipient, address(this));
        ISwapVM.Order memory order = createStrategy(_concentrateDynamicFeeProgram(address(feeProvider)));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, 1000e18, 1000e18);

        _drainTokenBToRangeBoundary(order, strategyHash);

        // Recipient already collected fees in tokenA during the drain — snapshot here
        (uint256 recipientBalanceABefore, uint256 recipientBalanceBBefore) = getProtocolRecipientBalances();

        // Swap back: tokenB (drained) -> tokenA
        SwapProgram memory backSwap = _swapProgram(10e18, false, true);
        mintTokenInToTaker(backSwap);

        // Quote agrees the swap back is possible (static context skips the fee pull)
        (, uint256 quotedAmountOut) = quote(backSwap, order);
        assertGt(quotedAmountOut, 0, "Quote for swap back should succeed");

        uint256 expectedFee = backSwap.amount * feeBps / BPS;
        vm.expectEmit(address(swapVM));
        emit FeeChargeFailed(swapVM.hash(order), address(tokenB), expectedFee, protocolFeeRecipient);

        (uint256 amountIn, uint256 amountOut) = swap(backSwap, order);

        assertEq(amountIn, backSwap.amount, "Swap back should consume the exact amountIn");
        assertGt(amountOut, 0, "Swap back should produce non-zero amountOut");
        assertEq(amountOut, quotedAmountOut, "Swap should match quote (quote/swap parity)");

        // Fee was skipped: recipient got nothing, the full amountIn stayed in the strategy
        (uint256 recipientBalanceAAfter, uint256 recipientBalanceBAfter) = getProtocolRecipientBalances();
        assertEq(recipientBalanceAAfter, recipientBalanceABefore, "Recipient balance A should not change");
        assertEq(recipientBalanceBAfter, recipientBalanceBBefore, "Recipient should not receive the skipped fee");
        (, uint256 aquaBalanceBAfter) = getAquaBalances(strategyHash);
        assertEq(aquaBalanceBAfter, amountIn, "Full amountIn incl. fee share should stay in the strategy");
    }
}
