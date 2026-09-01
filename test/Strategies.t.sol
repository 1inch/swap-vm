// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { Strategies } from "../src/strategies/Strategies.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../src/instructions/LimitSwap.sol";
import { XYCConcentrateSwap } from "../src/instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../src/instructions/FeeFlat.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut, PiecewiseLinearScale } from "../src/instructions/PiecewiseLinearScale.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../src/instructions/BaseFeeAdjuster.sol";
import { FulfillBonusBalanceIn, FulfillBonusBalanceOut } from "../src/instructions/FulfillBonus.sol";
import { BalanceScaleCutIn, BalanceScaleCutOut } from "../src/instructions/BalanceScaleCut.sol";
import { Deadline, Salt, Stop } from "../src/instructions/Controls.sol";

/**
 * @title Strategies
 * @notice Tests for Strategies order builders
 */
contract StrategiesTest is Test {
    Aqua public aqua;
    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    uint256 public makerPK = 0x1234;
    address public maker = vm.addr(0x1234);
    address public feeRecipient;

    function setUp() public {
        aqua = new Aqua();
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        (tokenA, tokenB) = (address(new TokenMock("Token I", "TKI")), address(new TokenMock("Token J", "TKJ")));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        TokenMock(tokenA).mint(maker, 1e31);
        TokenMock(tokenB).mint(maker, 1e31);
        TokenMock(tokenA).mint(address(this), 1e31);
        TokenMock(tokenB).mint(address(this), 1e31);

        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        feeRecipient = makeAddr("feeRecipient");
    }
    function test_Strategies_BuildIsazOrder() public view {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = Salt.build(uint64(42));

        Strategies.IsazOrder memory args = Strategies.IsazOrder({
            sqrtPriceMin: 0.9e18,
            sqrtPriceMax: 1.1e18,
            feeBps: 30000
        });

        assertEq(this.isazOrder(prefix, args), bytes.concat(
            Salt.build(uint64(42)),
            FeeFlatIn.build(30000),
            XYCConcentrateSwap.build(0.9e18, 1.1e18)
        ));
    }

    function test_Strategies_BuildWunjuOrder() public view {
        Strategies.WunjuOrder memory args = Strategies.WunjuOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: true,
            bitIndex: 42,
            fee: _fee(0.01e7, 0)
        });

        assertEq(this.wunjuOrder(true, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(false, args.fee.receivers, args.fee.providers, 0),
            InvalidateBit.build(42),
            LimitSwapFullAmount.build(true)
        ));

        assertEq(this.wunjuOrder(false, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(true, args.fee.receivers, args.fee.providers, 0),
            InvalidateBit.build(42),
            LimitSwapFullAmount.build(true)
        ));
    }

    function test_Strategies_BuildUruzOrder() public view {
        Strategies.UruzOrder memory args = Strategies.UruzOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: false,
            fee: _fee(0.01e7, 0)
        });

        assertEq(this.uruzOrder(true, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(false, args.fee.receivers, args.fee.providers, 0),
            InvalidateTokenIn.build(),
            LimitSwap.build(false)
        ));

        assertEq(this.uruzOrder(false, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(true, args.fee.receivers, args.fee.providers, 0),
            InvalidateTokenOut.build(),
            LimitSwap.build(false)
        ));
    }

    function test_Strategies_BuildThurisazOrder() public view {
        Strategies.ThurisazOrder memory args = Strategies.ThurisazOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: true,
            fee: _fee(0.01e7, 0.1e7),
            surplusEstimate: 80e18,
            scale: _scale()
        });

        assertEq(this.thurisazOrder(true, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(false, args.fee.receivers, args.fee.providers, 80e18),
            PiecewiseLinearScaleBalanceOut.build(args.scale.timestamp, args.scale.durations, args.scale.scales),
            InvalidateTokenIn.build(),
            LimitSwap.build(true)
        ));

        assertEq(this.thurisazOrder(false, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(true, args.fee.receivers, args.fee.providers, 80e18),
            PiecewiseLinearScaleBalanceIn.build(args.scale.timestamp, args.scale.durations, args.scale.scales),
            InvalidateTokenOut.build(),
            LimitSwap.build(true)
        ));
    }

    function test_Strategies_BuildFusionOrder() public view {
        Strategies.FusionOrder memory args = Strategies.FusionOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: true,
            fee: _fee(0.01e7, 0.1e7),
            surplusEstimate: 80e18,
            scale: _scale(),
            gasAdjustment: Strategies.ConfBaseFeeAdjustment({
                baseGasPrice: 25 gwei,
                ethPrice: 3500e18,
                gasAmount: 150_000,
                capBps: 0.01e7
            }),
            fulfillBonusBps: 0.005e7,
            rateCut: Strategies.ConfRateCut({ rateA: 1e18, rateB: 2e18 })
        });

        assertEq(this.fusionOrder(true, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(false, args.fee.receivers, args.fee.providers, 80e18),
            PiecewiseLinearScaleBalanceOut.build(args.scale.timestamp, args.scale.durations, args.scale.scales),
            BaseFeeAdjusterBalanceOut.build(25 gwei, 3500e18, 150_000, 0.01e7),
            InvalidateTokenIn.build(),
            FulfillBonusBalanceOut.build(0.005e7),
            BalanceScaleCutOut.build(1e18, 2e18),
            LimitSwap.build(true)
        ));

        assertEq(this.fusionOrder(false, new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeProtocol.build(true, args.fee.receivers, args.fee.providers, 80e18),
            PiecewiseLinearScaleBalanceIn.build(args.scale.timestamp, args.scale.durations, args.scale.scales),
            BaseFeeAdjusterBalanceIn.build(25 gwei, 3500e18, 150_000, 0.01e7),
            InvalidateTokenOut.build(),
            FulfillBonusBalanceIn.build(0.005e7),
            BalanceScaleCutIn.build(1e18, 2e18),
            LimitSwap.build(true)
        ));
    }

    function test_Strategies_RevertPrefixUnregistered() public {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = Stop.build();

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixUnregistered.selector, uint8(uint256(Stop.opcode))));
        this.isazOrder(prefix, Strategies.IsazOrder({ sqrtPriceMin: 0.9e18, sqrtPriceMax: 1.1e18, feeBps: 30000 }));
    }

    function test_Strategies_RevertPrefixTruncated() public {
        bytes memory instruction = Deadline.build(uint40(1e9));
        bytes memory truncated = new bytes(instruction.length - 1);
        for (uint256 i; i < truncated.length; i++) truncated[i] = instruction[i];

        bytes[] memory prefix = new bytes[](1);
        prefix[0] = truncated;

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixInvalidLength.selector, 6, 7));
        this.isazOrder(prefix, Strategies.IsazOrder({ sqrtPriceMin: 0.9e18, sqrtPriceMax: 1.1e18, feeBps: 30000 }));
    }

    function test_Strategies_RevertPrefixPadded() public {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = bytes.concat(Deadline.build(uint40(1e9)), hex"00");

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixInvalidLength.selector, 8, 7));
        this.isazOrder(prefix, Strategies.IsazOrder({ sqrtPriceMin: 0.9e18, sqrtPriceMax: 1.1e18, feeBps: 30000 }));
    }

    function test_Strategies_RevertFeeBpsOutOfRange() public {
        Strategies.IsazOrder memory args = Strategies.IsazOrder({
            sqrtPriceMin: 0.9e18,
            sqrtPriceMax: 1.1e18,
            feeBps: 1e7
        });

        vm.expectRevert(abi.encodeWithSelector(FeeFlatIn.FeeBpsOutOfRange.selector, 1e7));
        this.isazOrder(new bytes[](0), args);
    }

    function test_Strategies_RevertInvalidPriceBounds() public {
        Strategies.IsazOrder memory args = Strategies.IsazOrder({
            sqrtPriceMin: 1.1e18,
            sqrtPriceMax: 0.9e18,
            feeBps: 30000
        });

        vm.expectRevert(abi.encodeWithSelector(XYCConcentrateSwap.ConcentrateInvalidPriceBounds.selector, 1.1e18, 0.9e18));
        this.isazOrder(new bytes[](0), args);
    }

    /// @dev Maker exact in Thurisaz: at any point of a non-monotonic multipoint schedule, for either
    ///   direction and taker exact side, with any flat protocol fee, the maker pays at most the input
    ///   consumption priced at the biggest-scale rate
    function testFuzz_Strategies_QuoteThurisazOrderMakerExactInMaxPayment(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amount,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint256 warpTo,
        uint24 feeBps,
        bool isAToB,
        bool takerExactIn
    ) public {
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        warpTo = bound(warpTo, 1e9 - 1000, 1e9 + _boundDurations(durations) + 1000);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);
        amount = bound(amount, (takerExactIn ? balanceIn : balanceOut) / 1e4 + 1, (takerExactIn ? balanceIn : balanceOut) * 2);

        ISwapVM.Order memory order = _order(this.thurisazOrder(true, new bytes[](0), Strategies.ThurisazOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            })
        })), false);

        vm.warp(warpTo);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amount, _signedTakerData(order, isAToB, takerExactIn));

        (, uint24 biggestScale) = _scaleBounds(scales);

        // Maker input capacity is never exceeded; the flat token-out fee only reduces the taker receipt
        // below the curve output, so the payment bound at the biggest-scale rate keeps holding
        assertLe(quotedIn, balanceIn);
        assertLe(quotedOut * balanceIn, quotedIn * PiecewiseLinearScale.scaleValue(balanceOut, biggestScale));
    }

    /// @dev Maker exact out Thurisaz: at any point of a non-monotonic multipoint schedule, for either
    ///   direction and taker exact side, with any flat protocol fee, the maker receives at least the output
    ///   consumption priced at the lowest-scale rate
    function testFuzz_Strategies_QuoteThurisazOrderMakerExactOutMinReceipt(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amount,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint256 warpTo,
        uint24 feeBps,
        bool isAToB,
        bool takerExactIn
    ) public {
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        warpTo = bound(warpTo, 1e9 - 1000, 1e9 + _boundDurations(durations) + 1000);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);
        amount = bound(amount, (takerExactIn ? balanceIn : balanceOut) / 1e4 + 1, (takerExactIn ? balanceIn : balanceOut) * 2);

        ISwapVM.Order memory order = _order(this.thurisazOrder(false, new bytes[](0), Strategies.ThurisazOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            })
        })), false);

        vm.warp(warpTo);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amount, _signedTakerData(order, isAToB, takerExactIn));

        (uint24 lowestScale, ) = _scaleBounds(scales);

        // Maker output capacity is never exceeded; the flat token-in fee only adds to the taker payment
        // on top of the maker receipt, so the receipt bound at the lowest-scale rate keeps holding
        assertLe(quotedOut, balanceOut);
        assertLe(quotedOut * PiecewiseLinearScale.scaleValue(balanceIn, lowestScale), quotedIn * balanceOut);
    }

    function _boundDurations(uint16[3] memory durations) internal pure returns (uint256 total) {
        for (uint256 i; i < durations.length; i++) {
            durations[i] = uint16(bound(durations[i], 1, type(uint16).max));
            total += durations[i];
        }
    }

    function _scaleBounds(uint24[4] memory scales) internal pure returns (uint24 lowest, uint24 biggest) {
        lowest = type(uint24).max;
        for (uint256 i; i < scales.length; i++) {
            if (scales[i] < lowest) lowest = scales[i];
            if (scales[i] > biggest) biggest = scales[i];
        }
    }

    /// @dev Maker exact out surplus over both directions, schedule extremes and taker exact sides,
    ///   combined with a 50% flat fee the taker pays on top of the maker receipt: with the estimate set
    ///   at the lowest-scale receipt (50e18), the 10% surplus fee takes only from the receipt above the
    ///   guarantee (5e18 at the 1.0 scale, nothing at the 0.5 scale), so the maker receipt never falls
    ///   below the lowest-scale rate
    function test_Strategies_SwapThurisazOrderSurplusMakerExactOut() public {
        for (uint256 i; i < 8; i++) {
            bool isAToB = i < 4;
            bool highScale = (i % 4) < 2;
            bool takerExactIn = i % 2 == 0;

            bytes[] memory prefix = new bytes[](1);
            prefix[0] = Salt.build(uint64(i));

            ISwapVM.Order memory order = _order(this.thurisazOrder(false, prefix, Strategies.ThurisazOrder({
                balanceA: isAToB ? 100e18 : 200e18,
                balanceB: isAToB ? 200e18 : 100e18,
                direction: isAToB,
                fee: _fee(0.5e7, 0.1e7),
                surplusEstimate: 50e18,
                scale: _scale()
            })), false);

            vm.warp(highScale ? 1e9 - 1 : 1e9 + 3601);

            TokenMock tokenIn = TokenMock(isAToB ? tokenA : tokenB);
            uint256 netIn = highScale ? 100e18 : 50e18;
            uint256 makerBefore = tokenIn.balanceOf(maker);
            uint256 recipientBefore = tokenIn.balanceOf(feeRecipient);

            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order,
                takerExactIn ? netIn * 2 : 200e18,
                _signedTakerData(order, isAToB, takerExactIn)
            );

            // The 50% flat fee doubles the taker payment over the maker-side input
            assertEq(amountIn, netIn * 2);
            assertEq(amountOut, 200e18);
            assertEq(tokenIn.balanceOf(feeRecipient) - recipientBefore, netIn + (highScale ? 5e18 : 0));
            assertEq(tokenIn.balanceOf(maker) - makerBefore, highScale ? 95e18 : 50e18);
            assertGe(tokenIn.balanceOf(maker) - makerBefore, 50e18);
        }
    }

    /// @dev Maker exact in surplus over both directions, schedule extremes and taker exact sides,
    ///   combined with a 50% flat fee carved out of the taker receipt: with the estimate set at the
    ///   biggest-scale payment (200e18), the 10% surplus fee takes only from the payment saved below
    ///   the cap (10e18 at the 0.5 scale, nothing at the 1.0 scale), so the maker payment never
    ///   exceeds the biggest-scale rate
    function test_Strategies_SwapThurisazOrderSurplusMakerExactIn() public {
        for (uint256 i; i < 8; i++) {
            bool isAToB = i < 4;
            bool highScale = (i % 4) < 2;
            bool takerExactIn = i % 2 == 0;

            bytes[] memory prefix = new bytes[](1);
            prefix[0] = Salt.build(uint64(i));

            ISwapVM.Order memory order = _order(this.thurisazOrder(true, prefix, Strategies.ThurisazOrder({
                balanceA: isAToB ? 100e18 : 200e18,
                balanceB: isAToB ? 200e18 : 100e18,
                direction: isAToB,
                fee: _fee(0.5e7, 0.1e7),
                surplusEstimate: 200e18,
                scale: _scale()
            })), false);

            vm.warp(highScale ? 1e9 - 1 : 1e9 + 3601);

            TokenMock tokenOut = TokenMock(isAToB ? tokenB : tokenA);
            uint256 grossOut = highScale ? 200e18 : 100e18;
            uint256 makerBefore = tokenOut.balanceOf(maker);
            uint256 recipientBefore = tokenOut.balanceOf(feeRecipient);

            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order,
                takerExactIn ? 100e18 : grossOut / 2,
                _signedTakerData(order, isAToB, takerExactIn)
            );

            // The 50% flat fee halves the taker receipt below the maker-side output
            assertEq(amountIn, 100e18);
            assertEq(amountOut, grossOut / 2);
            assertEq(tokenOut.balanceOf(feeRecipient) - recipientBefore, grossOut / 2 + (highScale ? 0 : 10e18));
            assertEq(makerBefore - tokenOut.balanceOf(maker), highScale ? 200e18 : 110e18);
            assertLe(makerBefore - tokenOut.balanceOf(maker), 200e18);
        }
    }

    /// @dev Maker exact out Thurisaz over sequential fills: for any schedule, direction, flat fee, auction
    ///   points, fill sizes and exact sides, the cumulative output never exceeds the maker capacity and the
    ///   cumulative maker receipt (net of the taker-paid flat fee) keeps the lowest-scale rate
    function testFuzz_Strategies_SwapThurisazOrderMakerExactOutMultifill(
        uint256 balanceA,
        uint256 balanceB,
        uint256[3] memory amounts,
        uint256[3] memory warps,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint24 feeBps,
        bool isAToB,
        uint8 exactMask
    ) public {
        balanceA = bound(balanceA, 1e18, 1e24);
        balanceB = bound(balanceB, 1e18, 1e24);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        uint256 span = _boundDurations(durations);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);

        ISwapVM.Order memory order = _order(this.thurisazOrder(false, new bytes[](0), Strategies.ThurisazOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            })
        })), false);

        uint256 makerBefore = TokenMock(isAToB ? tokenA : tokenB).balanceOf(maker);
        uint256 time = 1e9 - 1000;
        uint256 totalOut;

        for (uint256 i; i < 3; i++) {
            uint256 remainingOut = balanceOut - totalOut;
            if (remainingOut <= balanceOut / 1e3) break;

            bool takerExactIn = (exactMask >> i) & 1 == 1;
            uint256 amount = takerExactIn
                ? bound(amounts[i], balanceIn / 1e4 + 1, balanceIn)
                : bound(amounts[i], remainingOut / 1e4 + 1, remainingOut / 2);

            time += bound(warps[i], 0, span);
            vm.warp(time);

            (, uint256 amountOut,) = swapVM.swap(order, amount, _signedTakerData(order, isAToB, takerExactIn));
            totalOut += amountOut;
        }

        (uint24 lowestScale, ) = _scaleBounds(scales);
        uint256 makerReceipt = TokenMock(isAToB ? tokenA : tokenB).balanceOf(maker) - makerBefore;

        assertLe(totalOut, balanceOut);
        assertLe(totalOut * PiecewiseLinearScale.scaleValue(balanceIn, lowestScale), makerReceipt * balanceOut);
    }

    /// @dev Maker exact in Thurisaz over sequential fills: for any schedule, direction, flat fee, auction
    ///   points, fill sizes and exact sides, the cumulative input never exceeds the maker capacity and the
    ///   cumulative maker payment (including the fee carved out of the taker receipt) keeps the biggest-scale rate
    function testFuzz_Strategies_SwapThurisazOrderMakerExactInMultifill(
        uint256 balanceA,
        uint256 balanceB,
        uint256[3] memory amounts,
        uint256[3] memory warps,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint24 feeBps,
        bool isAToB,
        uint8 exactMask
    ) public {
        balanceA = bound(balanceA, 1e18, 1e24);
        balanceB = bound(balanceB, 1e18, 1e24);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        uint256 span = _boundDurations(durations);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);

        ISwapVM.Order memory order = _order(this.thurisazOrder(true, new bytes[](0), Strategies.ThurisazOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            })
        })), false);

        uint256 makerBefore = TokenMock(isAToB ? tokenB : tokenA).balanceOf(maker);
        uint256 time = 1e9 - 1000;
        uint256 totalIn;

        for (uint256 i; i < 3; i++) {
            uint256 remainingIn = balanceIn - totalIn;
            if (remainingIn <= balanceIn / 1e3) break;

            bool takerExactIn = (exactMask >> i) & 1 == 1;
            uint256 amount = takerExactIn
                ? bound(amounts[i], remainingIn / 1e4 + 1, remainingIn)
                : bound(amounts[i], balanceOut / 1e4 + 1, balanceOut);

            time += bound(warps[i], 0, span);
            vm.warp(time);

            (uint256 amountIn,,) = swapVM.swap(order, amount, _signedTakerData(order, isAToB, takerExactIn));
            totalIn += amountIn;
        }

        (, uint24 biggestScale) = _scaleBounds(scales);
        uint256 makerPayment = makerBefore - TokenMock(isAToB ? tokenB : tokenA).balanceOf(maker);

        assertLe(totalIn, balanceIn);
        assertLe(makerPayment * balanceIn, totalIn * PiecewiseLinearScale.scaleValue(balanceOut, biggestScale));
    }

    /// @dev Maker exact in Fusion: for any schedule, gas adjustment, bonus, base fee, direction, flat fee
    ///   and taker exact side, the maker pays at most the input consumption priced at the BalanceScaleCut rate
    function testFuzz_Strategies_QuoteFusionOrderMakerExactInMaxPayment(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amount,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint256 warpTo,
        uint24 feeBps,
        uint24 bonusBps,
        uint64 rateA,
        uint64 rateB,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount,
        uint24 capBps,
        uint256 basefee,
        bool isAToB,
        bool takerExactIn
    ) public {
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        bonusBps = uint24(bound(bonusBps, 0, 0.5e7));
        capBps = uint24(bound(capBps, 0, 0.5e7));
        rateA = uint64(bound(rateA, 1, 1e6));
        rateB = uint64(bound(rateB, 1, 1e6));
        baseGasPrice = uint64(bound(baseGasPrice, 0, 1000 gwei));
        vm.fee(bound(basefee, 0, 2000 gwei));
        warpTo = bound(warpTo, 1e9 - 1000, 1e9 + _boundDurations(durations) + 1000);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);
        amount = bound(amount, (takerExactIn ? balanceIn : balanceOut) / 1e4 + 1, (takerExactIn ? balanceIn : balanceOut) * 2);

        ISwapVM.Order memory order = _order(this.fusionOrder(true, new bytes[](0), Strategies.FusionOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            }),
            gasAdjustment: Strategies.ConfBaseFeeAdjustment({
                baseGasPrice: baseGasPrice,
                ethPrice: ethPrice,
                gasAmount: gasAmount,
                capBps: capBps
            }),
            fulfillBonusBps: bonusBps,
            rateCut: Strategies.ConfRateCut({ rateA: rateA, rateB: rateB })
        })), false);

        vm.warp(warpTo);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amount, _signedTakerData(order, isAToB, takerExactIn));

        (uint64 rateIn, uint64 rateOut) = isAToB ? (rateA, rateB) : (rateB, rateA);

        // Maker input capacity is never exceeded; the taker receipt sits below the maker payment
        // by the flat token-out fee, so this is the taker-side projection of the cut-rate bound —
        // the exact maker payment is asserted by the multifill test via balance deltas
        assertLe(quotedIn, balanceIn);
        assertLe(quotedOut * rateIn, quotedIn * rateOut);
    }

    /// @dev Maker exact out Fusion: for any schedule, gas adjustment, bonus, base fee, direction, flat fee
    ///   and taker exact side, the maker receives at least the output consumption priced at the BalanceScaleCut rate
    function testFuzz_Strategies_QuoteFusionOrderMakerExactOutMinReceipt(
        uint256 balanceA,
        uint256 balanceB,
        uint256 amount,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint256 warpTo,
        uint24 feeBps,
        uint24 bonusBps,
        uint64 rateA,
        uint64 rateB,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount,
        uint24 capBps,
        uint256 basefee,
        bool isAToB,
        bool takerExactIn
    ) public {
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        bonusBps = uint24(bound(bonusBps, 0, 0.5e7));
        capBps = uint24(bound(capBps, 0, 0.5e7));
        rateA = uint64(bound(rateA, 1, 1e6));
        rateB = uint64(bound(rateB, 1, 1e6));
        baseGasPrice = uint64(bound(baseGasPrice, 0, 1000 gwei));
        vm.fee(bound(basefee, 0, 2000 gwei));
        warpTo = bound(warpTo, 1e9 - 1000, 1e9 + _boundDurations(durations) + 1000);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);
        amount = bound(amount, (takerExactIn ? balanceIn : balanceOut) / 1e4 + 1, (takerExactIn ? balanceIn : balanceOut) * 2);

        ISwapVM.Order memory order = _order(this.fusionOrder(false, new bytes[](0), Strategies.FusionOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            }),
            gasAdjustment: Strategies.ConfBaseFeeAdjustment({
                baseGasPrice: baseGasPrice,
                ethPrice: ethPrice,
                gasAmount: gasAmount,
                capBps: capBps
            }),
            fulfillBonusBps: bonusBps,
            rateCut: Strategies.ConfRateCut({ rateA: rateA, rateB: rateB })
        })), false);

        vm.warp(warpTo);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amount, _signedTakerData(order, isAToB, takerExactIn));

        (uint64 rateIn, uint64 rateOut) = isAToB ? (rateA, rateB) : (rateB, rateA);

        // Maker output capacity is never exceeded; the taker payment sits above the maker receipt
        // by the flat token-in fee, so this is the taker-side projection of the cut-rate bound —
        // the exact maker receipt is asserted by the multifill test via balance deltas
        assertLe(quotedOut, balanceOut);
        assertLe(quotedOut * rateIn, quotedIn * rateOut);
    }

    /// @dev Maker exact out Fusion surplus over both directions, schedule extremes and taker exact sides,
    ///   combined with a 50% flat fee the taker pays on top of the maker receipt: the 0.25 lowest scale
    ///   falls below the 1/4 cut floor, so the guarded receipt is 50e18; with the estimate at the cut floor
    ///   the 10% surplus fee takes only from the receipt above it (5e18 at the 1.0 scale, nothing at the
    ///   cut-floored lowest scale)
    function test_Strategies_SwapFusionOrderSurplusMakerExactOut() public {
        for (uint256 i; i < 8; i++) {
            bool isAToB = i < 4;
            bool highScale = (i % 4) < 2;
            bool takerExactIn = i % 2 == 0;

            bytes[] memory prefix = new bytes[](1);
            prefix[0] = Salt.build(uint64(i));

            ISwapVM.Order memory order = _order(this.fusionOrder(false, prefix, Strategies.FusionOrder({
                balanceA: isAToB ? 100e18 : 200e18,
                balanceB: isAToB ? 200e18 : 100e18,
                direction: isAToB,
                fee: _fee(0.5e7, 0.1e7),
                surplusEstimate: 50e18,
                scale: Strategies.ConfPiecewiseLinearScale({
                    timestamp: uint40(1e9),
                    durations: dynamic([uint16(100)]),
                    scales: dynamic([uint24(16777215), uint24(4194303)])
                }),
                gasAdjustment: Strategies.ConfBaseFeeAdjustment({ baseGasPrice: 0, ethPrice: 0, gasAmount: 0, capBps: 0 }),
                fulfillBonusBps: 0,
                rateCut: Strategies.ConfRateCut({ rateA: isAToB ? 1 : 4, rateB: isAToB ? 4 : 1 })
            })), false);

            vm.warp(highScale ? 1e9 - 1 : 1e9 + 101);

            TokenMock tokenIn = TokenMock(isAToB ? tokenA : tokenB);
            uint256 netIn = highScale ? 100e18 : 50e18;
            uint256 makerBefore = tokenIn.balanceOf(maker);
            uint256 recipientBefore = tokenIn.balanceOf(feeRecipient);

            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order,
                takerExactIn ? netIn * 2 : 200e18,
                _signedTakerData(order, isAToB, takerExactIn)
            );

            // The 50% flat fee doubles the taker payment over the maker-side input
            assertEq(amountIn, netIn * 2);
            assertEq(amountOut, 200e18);
            assertEq(tokenIn.balanceOf(feeRecipient) - recipientBefore, netIn + (highScale ? 5e18 : 0));
            assertEq(tokenIn.balanceOf(maker) - makerBefore, highScale ? 95e18 : 50e18);
            assertGe(tokenIn.balanceOf(maker) - makerBefore, 50e18);
        }
    }

    /// @dev Maker exact in Fusion surplus over both directions, schedule extremes and taker exact sides,
    ///   combined with a 50% flat fee carved out of the taker receipt: the 2/3 cut caps the 1.0-scale
    ///   payment at 150e18, so the guarded payment is 150e18; with the estimate at the cut cap the 10%
    ///   surplus fee takes only from the payment saved below it (5e18 at the 0.5 scale, nothing at the
    ///   cut-capped 1.0 scale)
    function test_Strategies_SwapFusionOrderSurplusMakerExactIn() public {
        for (uint256 i; i < 8; i++) {
            bool isAToB = i < 4;
            bool highScale = (i % 4) < 2;
            bool takerExactIn = i % 2 == 0;

            bytes[] memory prefix = new bytes[](1);
            prefix[0] = Salt.build(uint64(i));

            ISwapVM.Order memory order = _order(this.fusionOrder(true, prefix, Strategies.FusionOrder({
                balanceA: isAToB ? 100e18 : 200e18,
                balanceB: isAToB ? 200e18 : 100e18,
                direction: isAToB,
                fee: _fee(0.5e7, 0.1e7),
                surplusEstimate: 150e18,
                scale: _scale(),
                gasAdjustment: Strategies.ConfBaseFeeAdjustment({ baseGasPrice: 0, ethPrice: 0, gasAmount: 0, capBps: 0 }),
                fulfillBonusBps: 0,
                rateCut: Strategies.ConfRateCut({ rateA: isAToB ? 2 : 3, rateB: isAToB ? 3 : 2 })
            })), false);

            vm.warp(highScale ? 1e9 - 1 : 1e9 + 3601);

            TokenMock tokenOut = TokenMock(isAToB ? tokenB : tokenA);
            uint256 grossOut = highScale ? 150e18 : 100e18;
            uint256 makerBefore = tokenOut.balanceOf(maker);
            uint256 recipientBefore = tokenOut.balanceOf(feeRecipient);

            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
                order,
                takerExactIn ? 100e18 : grossOut / 2,
                _signedTakerData(order, isAToB, takerExactIn)
            );

            // The 50% flat fee halves the taker receipt below the maker-side output
            assertEq(amountIn, 100e18);
            assertEq(amountOut, grossOut / 2);
            assertEq(tokenOut.balanceOf(feeRecipient) - recipientBefore, grossOut / 2 + (highScale ? 0 : 5e18));
            assertEq(makerBefore - tokenOut.balanceOf(maker), highScale ? 150e18 : 105e18);
            assertLe(makerBefore - tokenOut.balanceOf(maker), 150e18);
        }
    }

    /// @dev Maker exact out Fusion over sequential fills: for any schedule, gas adjustment, bonus, base fee,
    ///   direction, flat fee, fill sizes and exact sides, the cumulative output never exceeds the maker
    ///   capacity and the cumulative maker receipt keeps the BalanceScaleCut rate
    function testFuzz_Strategies_SwapFusionOrderMakerExactOutMultifill(
        uint256 balanceA,
        uint256 balanceB,
        uint256[3] memory amounts,
        uint256[3] memory warps,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint24 feeBps,
        uint24 bonusBps,
        uint64 rateA,
        uint64 rateB,
        uint96 ethPrice,
        uint24 gasAmount,
        uint24 capBps,
        uint256 basefee,
        bool isAToB,
        uint8 exactMask
    ) public {
        balanceA = bound(balanceA, 1e18, 1e24);
        balanceB = bound(balanceB, 1e18, 1e24);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        bonusBps = uint24(bound(bonusBps, 0, 0.5e7));
        capBps = uint24(bound(capBps, 0, 0.5e7));
        rateA = uint64(bound(rateA, 1, 1e6));
        rateB = uint64(bound(rateB, 1, 1e6));
        vm.fee(bound(basefee, 0, 2000 gwei));
        uint256 span = _boundDurations(durations);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);

        ISwapVM.Order memory order = _order(this.fusionOrder(false, new bytes[](0), Strategies.FusionOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            }),
            gasAdjustment: Strategies.ConfBaseFeeAdjustment({
                baseGasPrice: 25 gwei,
                ethPrice: ethPrice,
                gasAmount: gasAmount,
                capBps: capBps
            }),
            fulfillBonusBps: bonusBps,
            rateCut: Strategies.ConfRateCut({ rateA: rateA, rateB: rateB })
        })), false);

        uint256 makerBefore = TokenMock(isAToB ? tokenA : tokenB).balanceOf(maker);
        uint256 time = 1e9 - 1000;
        uint256 totalOut;

        for (uint256 i; i < 3; i++) {
            uint256 remainingOut = balanceOut - totalOut;
            if (remainingOut <= balanceOut / 1e3) break;

            bool takerExactIn = (exactMask >> i) & 1 == 1;
            uint256 amount = takerExactIn
                ? bound(amounts[i], balanceIn / 1e4 + 1, balanceIn)
                : bound(amounts[i], remainingOut / 1e4 + 1, remainingOut / 2);

            time += bound(warps[i], 0, span);
            vm.warp(time);

            (, uint256 amountOut,) = swapVM.swap(order, amount, _signedTakerData(order, isAToB, takerExactIn));
            totalOut += amountOut;
        }

        (uint64 rateIn, uint64 rateOut) = isAToB ? (rateA, rateB) : (rateB, rateA);
        uint256 makerReceipt = TokenMock(isAToB ? tokenA : tokenB).balanceOf(maker) - makerBefore;

        assertLe(totalOut, balanceOut);
        assertLe(totalOut * rateIn, makerReceipt * rateOut);
    }

    /// @dev Maker exact in Fusion over sequential fills: for any schedule, gas adjustment, bonus, base fee,
    ///   direction, flat fee, fill sizes and exact sides, the cumulative input never exceeds the maker
    ///   capacity and the cumulative maker payment keeps the BalanceScaleCut rate
    function testFuzz_Strategies_SwapFusionOrderMakerExactInMultifill(
        uint256 balanceA,
        uint256 balanceB,
        uint256[3] memory amounts,
        uint256[3] memory warps,
        uint24[4] memory scales,
        uint16[3] memory durations,
        uint24 feeBps,
        uint24 bonusBps,
        uint64 rateA,
        uint64 rateB,
        uint96 ethPrice,
        uint24 gasAmount,
        uint24 capBps,
        uint256 basefee,
        bool isAToB,
        uint8 exactMask
    ) public {
        balanceA = bound(balanceA, 1e18, 1e24);
        balanceB = bound(balanceB, 1e18, 1e24);
        feeBps = uint24(bound(feeBps, 0, 0.05e7));
        bonusBps = uint24(bound(bonusBps, 0, 0.5e7));
        capBps = uint24(bound(capBps, 0, 0.5e7));
        rateA = uint64(bound(rateA, 1, 1e6));
        rateB = uint64(bound(rateB, 1, 1e6));
        vm.fee(bound(basefee, 0, 2000 gwei));
        uint256 span = _boundDurations(durations);
        (uint256 balanceIn, uint256 balanceOut) = isAToB ? (balanceA, balanceB) : (balanceB, balanceA);

        ISwapVM.Order memory order = _order(this.fusionOrder(true, new bytes[](0), Strategies.FusionOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: isAToB,
            fee: feeBps == 0 ? _noFee() : _fee(feeBps, 0),
            surplusEstimate: 0,
            scale: Strategies.ConfPiecewiseLinearScale({
                timestamp: uint40(1e9),
                durations: dynamic(durations),
                scales: dynamic(scales)
            }),
            gasAdjustment: Strategies.ConfBaseFeeAdjustment({
                baseGasPrice: 25 gwei,
                ethPrice: ethPrice,
                gasAmount: gasAmount,
                capBps: capBps
            }),
            fulfillBonusBps: bonusBps,
            rateCut: Strategies.ConfRateCut({ rateA: rateA, rateB: rateB })
        })), false);

        uint256 makerBefore = TokenMock(isAToB ? tokenB : tokenA).balanceOf(maker);
        uint256 time = 1e9 - 1000;
        uint256 totalIn;

        for (uint256 i; i < 3; i++) {
            uint256 remainingIn = balanceIn - totalIn;
            if (remainingIn <= balanceIn / 1e3) break;

            bool takerExactIn = (exactMask >> i) & 1 == 1;
            uint256 amount = takerExactIn
                ? bound(amounts[i], remainingIn / 1e4 + 1, remainingIn)
                : bound(amounts[i], balanceOut / 1e4 + 1, balanceOut);

            time += bound(warps[i], 0, span);
            vm.warp(time);

            (uint256 amountIn,,) = swapVM.swap(order, amount, _signedTakerData(order, isAToB, takerExactIn));
            totalIn += amountIn;
        }

        (uint64 rateIn, uint64 rateOut) = isAToB ? (rateA, rateB) : (rateB, rateA);
        uint256 makerPayment = makerBefore - TokenMock(isAToB ? tokenB : tokenA).balanceOf(maker);

        assertLe(totalIn, balanceIn);
        assertLe(makerPayment * rateIn, totalIn * rateOut);
    }

    function testFuzz_Strategies_QuoteIsazOrderInBounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 amountIn,
        uint256 feeBps,
        bool isAToB
    ) public {
        feeBps = bound(feeBps, 0, 0.01e7);
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        sqrtPriceMin = bound(sqrtPriceMin, 0.1e18, 10e18);
        sqrtPriceMax = bound(sqrtPriceMax, sqrtPriceMin * 2, 20e18);
        uint256 balanceIn = isAToB ? balanceA : balanceB;
        amountIn = bound(amountIn, balanceIn / 1e4 + 1, balanceIn * 100);

        ISwapVM.Order memory order = _order(this.isazOrder(new bytes[](0), Strategies.IsazOrder({
            sqrtPriceMin: sqrtPriceMin,
            sqrtPriceMax: sqrtPriceMax,
            feeBps: uint24(feeBps)
        })), true);

        // AMM order takes balances from Aqua
        vm.prank(maker);
        aqua.ship(address(swapVM), abi.encode(order), dynamic([tokenA, tokenB]), dynamic([balanceA, balanceB]));

        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amountIn, _takerData("", isAToB));

        // Maker never pays out beyond the shipped reserves and never sells cheaper than the direction's range corner
        if (isAToB) {
            assertLe(quotedOut, balanceB);
            assertLe(quotedOut * 1e36, quotedIn * sqrtPriceMax * sqrtPriceMax);
        } else {
            assertLe(quotedOut, balanceA);
            assertLe(quotedOut * sqrtPriceMin * sqrtPriceMin, quotedIn * 1e36);
        }
    }

    function _noFee() internal pure returns (Strategies.ConfProtocolFee memory) {
        return Strategies.ConfProtocolFee({
            receivers: new FeeProtocol.ReceiverConfig[](0),
            providers: new FeeProtocol.ProviderConfig[](0)
        });
    }

    function _fee(uint24 feeBps, uint24 surplusBps) internal view returns (Strategies.ConfProtocolFee memory) {
        FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: feeRecipient, feeBps: feeBps, surplusBps: surplusBps });

        return Strategies.ConfProtocolFee({ receivers: receivers, providers: new FeeProtocol.ProviderConfig[](0) });
    }

    function _scale() internal pure returns (Strategies.ConfPiecewiseLinearScale memory) {
        return Strategies.ConfPiecewiseLinearScale({
            timestamp: uint40(1e9),
            durations: dynamic([uint16(3600)]),
            scales: dynamic([uint24(16777215), uint24(8388607)])
        });
    }

    function _order(bytes memory program, bool useAqua) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: useAqua,
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

    function _signedTakerData(ISwapVM.Order memory order, bool isAToB, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        return _takerData(abi.encodePacked(r, s, v), isAToB, isExactIn);
    }

    function _takerData(bytes memory signature, bool isAToB) internal pure returns (bytes memory) {
        return _takerData(signature, isAToB, true);
    }

    function _takerData(bytes memory signature, bool isAToB, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: true,
            threshold: "",
            to: address(0),
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

    // Externals routing memory test data into the calldata-only builders

    function isazOrder(
        bytes[] calldata prefix,
        Strategies.IsazOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildIsazOrder(prefix, args);
    }

    function wunjuOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        Strategies.WunjuOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildWunjuOrder(makerExactIn, prefix, args);
    }

    function uruzOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        Strategies.UruzOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildUruzOrder(makerExactIn, prefix, args);
    }

    function thurisazOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        Strategies.ThurisazOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildThurisazOrder(makerExactIn, prefix, args);
    }

    function fusionOrder(
        bool makerExactIn,
        bytes[] calldata prefix,
        Strategies.FusionOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildFusionOrder(makerExactIn, prefix, args);
    }
}
