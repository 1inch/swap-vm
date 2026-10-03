// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { InvalidateTokenIn, InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import {
    PiecewiseLinearSurchargeBalanceIn,
    PiecewiseLinearSurchargeBalanceOut
} from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import {
    FillGridPiecewiseAdjusterBalanceIn,
    FillGridPiecewiseAdjusterBalanceOut
} from "../../contracts/instructions/FillGridPiecewiseAdjuster.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";

contract GridBuildHelper {
    function buildIn(uint24[] memory fillBps, uint24[] memory adjustBps) external pure returns (bytes memory) {
        return FillGridPiecewiseAdjusterBalanceIn.build(fillBps, adjustBps);
    }

    function buildOut(uint24[] memory fillBps, uint24[] memory adjustBps) external pure returns (bytes memory) {
        return FillGridPiecewiseAdjusterBalanceOut.build(fillBps, adjustBps);
    }
}

contract FillGridPiecewiseAdjusterTest is Test {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    uint256 private constant MAKER_PRIVATE_KEY = 0xBEEF;

    address public maker;

    enum InvalidationScope {
        Total,
        Remaining
    }

    function setUp() public {
        maker = vm.addr(MAKER_PRIVATE_KEY);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e35);
        tokenB.mint(maker, 1e35);
        tokenA.mint(address(this), 1e35);
        tokenB.mint(address(this), 1e35);

        vm.startPrank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_FillGridPiecewiseAdjusterBalanceIn_ExactOut_Basic() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        (uint256 amountIn95,,) = swapVM.quote(order, 950e18, takerData);
        (uint256 amountIn5,,) = swapVM.quote(order, 50e18, takerData);

        assertEq(amountIn95, 1379.875e18);
        assertEq(amountIn5, 74.875e18);
    }

    function test_FillGridPiecewiseAdjusterBalanceOut_ExactIn_Basic() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        (, uint256 amountOut95,) = swapVM.quote(order, 950e18, takerData);
        (, uint256 amountOut5,) = swapVM.quote(order, 50e18, takerData);

        assertEq(amountOut95, 995.125e18);
        assertEq(amountOut5, 50.125e18);
    }

    function test_FillGridPiecewiseAdjusterBalanceIn_ExactOut_GridPoints() public view {
        uint256[4] memory amountsOut = [uint256(200e18), 500e18, 800e18, 1000e18];
        uint256[4] memory expectedAmountsIn = [uint256(298e18), 737.5e18, 1168e18, 1450e18];

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        for (uint256 i; i < amountsOut.length; i++) {
            (uint256 amountIn,,) = swapVM.quote(order, amountsOut[i], takerData);
            assertEq(amountIn, expectedAmountsIn[i]);
        }
    }

    function test_FillGridPiecewiseAdjusterBalanceIn_ExactIn_GridPoints() public view {
        uint256[4] memory amountsIn = [uint256(298e18), 737.5e18, 1168e18, 1450e18];
        uint256[4] memory expectedAmountsOut = [uint256(200e18), 500e18, 800e18, 1000e18];

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        for (uint256 i; i < amountsIn.length; i++) {
            (, uint256 amountOut,) = swapVM.quote(order, amountsIn[i], takerData);
            assertEq(amountOut, expectedAmountsOut[i]);
        }
    }

    function test_FillGridPiecewiseAdjusterBalanceOut_ExactIn_GridPoints() public view {
        uint256[4] memory amountsIn = [uint256(200e18), 500e18, 800e18, 1000e18];
        uint256[4] memory expectedAmountsOut = [uint256(202e18), 512.5e18, 832e18, 1050e18];

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        for (uint256 i; i < amountsIn.length; i++) {
            (, uint256 amountOut,) = swapVM.quote(order, amountsIn[i], takerData);
            assertEq(amountOut, expectedAmountsOut[i]);
        }
    }

    function test_FillGridPiecewiseAdjusterBalanceOut_ExactOut_GridPoints() public view {
        uint256[4] memory amountsOut = [uint256(202e18), 512.5e18, 832e18, 1050e18];
        uint256[4] memory expectedAmountsIn = [uint256(200e18), 500e18, 800e18, 1000e18];

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        for (uint256 i; i < amountsOut.length; i++) {
            (uint256 amountIn,,) = swapVM.quote(order, amountsOut[i], takerData);
            assertEq(amountIn, expectedAmountsIn[i]);
        }
    }

    function test_FillGridPiecewiseAdjusterBalanceIn_ExactOut_Midpoint() public view {
        // 350 out = 35% fill between 20% (0.98) and 50% (0.95): adjust 0.965, surcharge 482.5, balance 1482.5
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        (uint256 amountIn,,) = swapVM.quote(order, 350e18, _buildTakerData(order, false));
        assertEq(amountIn, 518.875e18);
    }

    function test_FillGridPiecewiseAdjusterBalanceOut_ExactIn_Midpoint() public view {
        // 350 in = 35% fill: balanceOut 1017.5, out 356.125
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        (, uint256 amountOut,) = swapVM.quote(order, 350e18, _buildTakerData(order, true));
        assertEq(amountOut, 356.125e18);
    }

    function test_FillGridPiecewiseAdjuster_ZeroAdjustment() public view {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = 0;

        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        uint24[] memory fillBps = new uint24[](2);
        uint24[] memory adjustBps = new uint24[](2);
        fillBps[0] = 0; adjustBps[0] = 1e7;
        fillBps[1] = 1e7; adjustBps[1] = 1e7;

        ISwapVM.Order memory balanceInOrder = _buildOrder(
            bytes.concat(
                StaticBalances.build(balanceIn, balanceOut),
                PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales),
                FillGridPiecewiseAdjusterBalanceIn.build(fillBps, adjustBps),
                LimitSwap.build(address(tokenA), address(tokenB))
            )
        );
        ISwapVM.Order memory balanceOutOrder = _buildOrder(
            bytes.concat(
                StaticBalances.build(balanceIn, balanceOut),
                PiecewiseLinearSurchargeBalanceOut.build(uint40(block.timestamp), durations, scales),
                FillGridPiecewiseAdjusterBalanceOut.build(fillBps, adjustBps),
                LimitSwap.build(address(tokenA), address(tokenB))
            )
        );

        (uint256 quotedIn,,) = swapVM.quote(balanceInOrder, 50e18, _buildTakerData(balanceInOrder, false));
        (, uint256 quotedOut,) = swapVM.quote(balanceOutOrder, 50e18, _buildTakerData(balanceOutOrder, true));

        assertEq(quotedIn, 50e18);
        assertEq(quotedOut, 50e18);
    }

    function test_FillGridPiecewiseAdjuster_Build_Reverts() public {
        GridBuildHelper helper = new GridBuildHelper();

        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterNoPoints.selector);
        helper.buildIn(new uint24[](0), new uint24[](0));

        uint24[] memory fillBps = new uint24[](2);
        uint24[] memory adjustBps = new uint24[](1);
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterMismatchInputLengths.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps = new uint24[](2);
        adjustBps = new uint24[](2);
        fillBps[0] = 0.1e7; adjustBps[0] = 1e7;
        fillBps[1] = 1e7; adjustBps[1] = 0.9e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterInvalidEndpoints.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps[0] = 0; adjustBps[0] = 0.9e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterInvalidEndpoints.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps[0] = 0; adjustBps[0] = 1e7;
        fillBps[1] = 0.9e7; adjustBps[1] = 0.9e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterInvalidEndpoints.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps = new uint24[](4);
        adjustBps = new uint24[](4);
        fillBps[0] = 0; adjustBps[0] = 1e7;
        fillBps[1] = 0.5e7; adjustBps[1] = 0.95e7;
        fillBps[2] = 0.5e7; adjustBps[2] = 0.9e7;
        fillBps[3] = 1e7; adjustBps[3] = 0.9e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterNonAscendingFillBps.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps[2] = 0.8e7; adjustBps[2] = 0.96e7;
        fillBps[3] = 1e7; adjustBps[3] = 0.96e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterIncreasingAdjustBps.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps = new uint24[](3);
        adjustBps = new uint24[](3);
        fillBps[0] = 0; adjustBps[0] = 1e7;
        fillBps[1] = 0.5e7; adjustBps[1] = 0.95e7;
        fillBps[2] = 1e7; adjustBps[2] = 0.5e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceIn.FillGridPiecewiseAdjusterDecreasingFillCapacity.selector);
        helper.buildIn(fillBps, adjustBps);

        fillBps = new uint24[](1);
        adjustBps = new uint24[](1);
        fillBps[0] = 0.1e7; adjustBps[0] = 0.9e7;
        vm.expectRevert(FillGridPiecewiseAdjusterBalanceOut.FillGridPiecewiseAdjusterInvalidEndpoints.selector);
        helper.buildOut(fillBps, adjustBps);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceIn_ExactIn_MatchesReference(
        uint256 amountSeed,
        uint8 pointSeed
    ) public view {
        uint256[4] memory minAmountsIn = [uint256(2), 298e18, 737.5e18, 1168e18];
        uint256[4] memory upperBounds = [uint256(298e18), 737.5e18, 1168e18, 1450e18];
        uint256[4] memory referenceBalancesIn = [uint256(1500e18), 1490e18, 1475e18, 1460e18];
        uint256 point = bound(pointSeed, 0, 3);
        uint256 amountIn = minAmountsIn[point] + amountSeed % (upperBounds[point] - minAmountsIn[point]);

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder =
            _buildOrder(_buildReferenceProgram(referenceBalancesIn[point], 1000e18));

        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 referenceAmountOut,) = swapVM.quote(referenceOrder, amountIn, _buildTakerData(referenceOrder, true));

        if (amountIn == upperBounds[point]) assertEq(amountOut, referenceAmountOut);
        else assertGe(amountOut, referenceAmountOut);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceIn_ExactOut_MatchesReference(
        uint256 amountSeed,
        uint8 pointSeed
    ) public view {
        uint256[4] memory minAmountsOut = [uint256(1), 200e18, 500e18, 800e18];
        uint256[4] memory upperBounds = [uint256(200e18), 500e18, 800e18, 1000e18];
        uint256[4] memory referenceBalancesIn = [uint256(1500e18), 1490e18, 1475e18, 1460e18];
        uint256 point = bound(pointSeed, 0, 3);
        uint256 amountOut = minAmountsOut[point] + amountSeed % (upperBounds[point] - minAmountsOut[point]);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder = _buildOrder(_buildReferenceProgram(referenceBalancesIn[point], 1000e18));

        (uint256 amountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        (uint256 referenceAmountIn,,) = swapVM.quote(referenceOrder, amountOut, _buildTakerData(referenceOrder, false));

        if (amountOut == upperBounds[point]) assertEq(amountIn, referenceAmountIn);
        else assertLe(amountIn, referenceAmountIn);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceOut_ExactIn_MatchesReference(
        uint256 amountSeed,
        uint8 pointSeed
    ) public view {
        uint256[4] memory minAmountsIn = [uint256(1), 200e18, 500e18, 800e18];
        uint256[4] memory upperBounds = [uint256(200e18), 500e18, 800e18, 1000e18];
        uint256[4] memory referenceBalancesOut = [uint256(1010e18), 1025e18, 1040e18, 1050e18];
        uint256 point = bound(pointSeed, 0, 3);
        uint256 amountIn = minAmountsIn[point] + amountSeed % (upperBounds[point] - minAmountsIn[point]);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder = _buildOrder(_buildReferenceProgram(1000e18, referenceBalancesOut[point]));

        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 referenceAmountOut,) = swapVM.quote(referenceOrder, amountIn, _buildTakerData(referenceOrder, true));

        if (amountIn == upperBounds[point]) assertEq(amountOut, referenceAmountOut);
        else assertLe(amountOut, referenceAmountOut);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceOut_ExactOut_MatchesReference(
        uint256 amountSeed,
        uint8 pointSeed
    ) public view {
        uint256[4] memory minAmountsOut = [uint256(1), 202e18, 512.5e18, 832e18];
        uint256[4] memory upperBounds = [uint256(202e18), 512.5e18, 832e18, 1050e18];
        uint256[4] memory referenceBalancesOut = [uint256(1010e18), 1025e18, 1040e18, 1050e18];
        uint256 point = bound(pointSeed, 0, 3);
        uint256 amountOut = minAmountsOut[point] + amountSeed % (upperBounds[point] - minAmountsOut[point]);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder = _buildOrder(_buildReferenceProgram(1000e18, referenceBalancesOut[point]));

        (uint256 amountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        (uint256 referenceAmountIn,,) = swapVM.quote(referenceOrder, amountOut, _buildTakerData(referenceOrder, false));

        if (amountOut == upperBounds[point]) assertEq(amountIn, referenceAmountIn);
        else assertGe(amountIn, referenceAmountIn);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceIn_TotalVsRemainingVolume(
        uint24 surchargeScaleSeed,
        uint8 firstFillPercentSeed
    ) public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24(bound(surchargeScaleSeed, 1, type(uint24).max));
        uint256 firstAmountOut = balanceOut * bound(firstFillPercentSeed, 1, 9) / 100;
        uint256 remainingOut = balanceOut - firstAmountOut;
        uint256 secondAmountOut = remainingOut / 2;

        ISwapVM.Order memory totalOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, true, InvalidationScope.Total));
        ISwapVM.Order memory remainingOrder =
            _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, true, InvalidationScope.Remaining));
        bytes memory totalData = _buildTakerData(totalOrder, false);
        bytes memory remainingData = _buildTakerData(remainingOrder, false);

        (uint256 totalAmountInBeforeFill,,) = swapVM.quote(totalOrder, secondAmountOut, totalData);
        (uint256 remainingAmountInBeforeFill,,) = swapVM.quote(remainingOrder, secondAmountOut, remainingData);
        assertEq(totalAmountInBeforeFill, remainingAmountInBeforeFill);

        swapVM.swap(totalOrder, firstAmountOut, totalData);
        swapVM.swap(remainingOrder, firstAmountOut, remainingData);

        (uint256 totalAmountIn,,) = swapVM.quote(totalOrder, secondAmountOut, totalData);
        (uint256 remainingAmountIn,,) = swapVM.quote(remainingOrder, secondAmountOut, remainingData);

        assertLt(remainingAmountIn, totalAmountIn);
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(totalOrder), address(tokenB)), firstAmountOut);
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(remainingOrder), address(tokenB)), firstAmountOut);
    }

    function testFuzz_FillGridPiecewiseAdjusterBalanceOut_TotalVsRemainingVolume(
        uint24 surchargeScaleSeed,
        uint8 firstFillPercentSeed
    ) public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24(bound(surchargeScaleSeed, 1, type(uint24).max));
        uint256 firstAmountIn = balanceIn * bound(firstFillPercentSeed, 1, 9) / 100;
        uint256 remainingIn = balanceIn - firstAmountIn;
        uint256 secondAmountIn = remainingIn / 2;

        ISwapVM.Order memory totalOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, false, InvalidationScope.Total));
        ISwapVM.Order memory remainingOrder =
            _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, false, InvalidationScope.Remaining));
        bytes memory totalData = _buildTakerData(totalOrder, true);
        bytes memory remainingData = _buildTakerData(remainingOrder, true);

        (, uint256 totalAmountOutBeforeFill,) = swapVM.quote(totalOrder, secondAmountIn, totalData);
        (, uint256 remainingAmountOutBeforeFill,) = swapVM.quote(remainingOrder, secondAmountIn, remainingData);
        assertEq(totalAmountOutBeforeFill, remainingAmountOutBeforeFill);

        swapVM.swap(totalOrder, firstAmountIn, totalData);
        swapVM.swap(remainingOrder, firstAmountIn, remainingData);

        (, uint256 totalAmountOut,) = swapVM.quote(totalOrder, secondAmountIn, totalData);
        (, uint256 remainingAmountOut,) = swapVM.quote(remainingOrder, secondAmountIn, remainingData);

        assertGt(remainingAmountOut, totalAmountOut);
        assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(totalOrder), address(tokenA)), firstAmountIn);
        assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(remainingOrder), address(tokenA)), firstAmountIn);
    }

    function testFuzz_FillGridPiecewise_InAndOutQuotesMatch(uint256 balanceSeed) public view {
        // Single balance on both sides avoids partial-fill regime; BalanceIn (discount) vs BalanceOut (boost)
        // apply the same grid asymmetrically, so parity holds within ~2% (vs wei-level for surcharge-only).
        uint256 balance = bound(balanceSeed, 1e18, 1e21);

        ISwapVM.Order memory balanceInOrder = _buildOrder(_buildProgram(balance, balance, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory balanceOutOrder = _buildOrder(_buildProgram(balance, balance, 1 << 23, false, InvalidationScope.Total));

        bytes memory balanceInOrderExactIn = _buildTakerData(balanceInOrder, true);
        bytes memory balanceInOrderExactOut = _buildTakerData(balanceInOrder, false);
        bytes memory balanceOutOrderExactIn = _buildTakerData(balanceOutOrder, true);
        bytes memory balanceOutOrderExactOut = _buildTakerData(balanceOutOrder, false);

        (uint256 amountInWithBalanceInAdjuster,,) = swapVM.quote(balanceInOrder, balance / 2, balanceInOrderExactOut);
        (uint256 amountInWithBalanceOutAdjuster,,) = swapVM.quote(balanceOutOrder, balance / 2, balanceOutOrderExactOut);

        (, uint256 amountOutWithBalanceInAdjuster,) = swapVM.quote(balanceInOrder, balance / 2, balanceInOrderExactIn);
        (, uint256 amountOutWithBalanceOutAdjuster,) = swapVM.quote(balanceOutOrder, balance / 2, balanceOutOrderExactIn);

        assertApproxEqRel(amountInWithBalanceInAdjuster, amountInWithBalanceOutAdjuster, 0.02e18);
        assertApproxEqRel(amountOutWithBalanceInAdjuster, amountOutWithBalanceOutAdjuster, 0.02e18);
    }

    function _grid() private pure returns (uint24[] memory fillBps, uint24[] memory adjustBps) {
        fillBps = new uint24[](5);
        adjustBps = new uint24[](5);
        fillBps[0] = 0; adjustBps[0] = 1e7;
        fillBps[1] = 0.2e7; adjustBps[1] = 0.98e7;
        fillBps[2] = 0.5e7; adjustBps[2] = 0.95e7;
        fillBps[3] = 0.8e7; adjustBps[3] = 0.92e7;
        fillBps[4] = 1e7; adjustBps[4] = 0.90e7;
    }

    function _buildProgram(
        uint256 balanceIn,
        uint256 balanceOut,
        uint24 surchargeScale,
        bool scaleIn,
        InvalidationScope scope
    ) private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        (uint24[] memory fillBps, uint24[] memory adjustBps) = _grid();
        bytes memory balances = StaticBalances.build(balanceIn, balanceOut);
        bytes memory surcharge = scaleIn
            ? PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales)
            : PiecewiseLinearSurchargeBalanceOut.build(uint40(block.timestamp), durations, scales);
        bytes memory adjuster = scaleIn
            ? FillGridPiecewiseAdjusterBalanceIn.build(fillBps, adjustBps)
            : FillGridPiecewiseAdjusterBalanceOut.build(fillBps, adjustBps);
        bytes memory invalidator = scaleIn ? InvalidateTokenOut.build() : InvalidateTokenIn.build();
        bytes memory swap = LimitSwap.build(address(tokenA), address(tokenB));

        if (scope == InvalidationScope.Total) return bytes.concat(balances, surcharge, adjuster, invalidator, swap);
        return bytes.concat(balances, surcharge, invalidator, adjuster, swap);
    }

    function _buildReferenceProgram(uint256 balanceIn, uint256 balanceOut) private view returns (bytes memory) {
        return bytes.concat(StaticBalances.build(balanceIn, balanceOut), LimitSwap.build(address(tokenA), address(tokenB)));
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
            allowZeroAmountIn: true,
            program: program
        }));
    }

    function _buildTakerData(ISwapVM.Order memory order, bool exactIn) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: exactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
            usePermit2: false,
            threshold: "",
            to: address(this),
            hasPreTransferInCallback: false,
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
