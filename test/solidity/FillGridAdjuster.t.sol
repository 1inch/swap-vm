// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { PiecewiseLinearSurcharge } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { FillGridAdjuster } from "../../contracts/instructions/FillGridAdjuster.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";

contract FillGridAdjusterTest is Test {
    uint256 private constant MAKER_PRIVATE_KEY = 0xBEEF;
    uint256 private constant BPS = 1e7;
    uint256 private constant ONE = 1e18;

    SwapVMRouter private swapVM;
    TraitsHelper private orders;
    TokenMock private tokenA;
    TokenMock private tokenB;
    address private maker;

    function setUp() public {
        maker = vm.addr(MAKER_PRIVATE_KEY);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function test_FillGridAdjusterBalanceIn_BuildRejectsPotentialAmountInInversion() public {
        uint24[] memory fillBps = new uint24[](3);
        uint24[] memory adjustBps = new uint24[](3);

        fillBps[0] = 0;
        fillBps[1] = 0.3e7;
        fillBps[2] = 0.35e7;
        adjustBps[0] = 1e7;
        adjustBps[1] = 1e7;
        adjustBps[2] = 0.5e7;

        vm.expectRevert(FillGridAdjuster.FillGridAdjusterNotMonotonic.selector);
        this.buildFillGridAdjusterBalanceIn(fillBps, adjustBps);
    }

    function test_FillGridAdjusterBalanceIn_BuildRejectsPotentialEndpointCollision() public {
        uint24[] memory fillBps = new uint24[](2);
        uint24[] memory adjustBps = new uint24[](2);

        fillBps[0] = 0;
        fillBps[1] = 0.5e7;
        adjustBps[0] = 1e7;
        adjustBps[1] = 1e7;

        vm.expectRevert(FillGridAdjuster.FillGridAdjusterNotMonotonic.selector);
        this.buildFillGridAdjusterBalanceIn(fillBps, adjustBps);
    }

    function test_FillGridAdjusterBalanceIn_ExactIn_QuotesAmountwiseInterpolation() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, true));

        (uint256 amountIn, uint256 amountOut,) = swapVM.quote(order, 459e18, _buildTakerData(order, true));

        assertEq(amountIn, 459e18);
        assertEq(amountOut, 299_510_603_588_907_014_681);
    }

    function test_FillGridAdjusterBalanceIn_ExactOut_QuotesAmountwiseInterpolation() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 1000e18, true));

        (uint256 amountIn, uint256 amountOut,) = swapVM.quote(order, 306e18, _buildTakerData(order, false));

        assertEq(amountIn, 468_796_112_071_496_134_904);
        assertEq(amountOut, 306e18);
    }

    function test_FillGridAdjusterBalanceOut_ExactIn_QuotesAmountwiseInterpolation() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1500e18, 1500e18, false));

        (uint256 amountIn, uint256 amountOut,) = swapVM.quote(order, 450e18, _buildTakerData(order, true));

        assertEq(amountIn, 450e18);
        assertEq(amountOut, 293_637_846_655_791_190_864);
    }

    function test_FillGridAdjusterBalanceOut_ExactOut_QuotesAmountwiseInterpolation() public view {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(1500e18, 1500e18, false));

        (uint256 amountIn, uint256 amountOut,) = swapVM.quote(order, 300e18, _buildTakerData(order, false));

        assertEq(amountIn, 459_605_911_330_049_261_084);
        assertEq(amountOut, 300e18);
    }

    function testFuzz_FillGridAdjusterBalanceIn_PriceIsLinearByAmountIn(uint256 amountIn) public view {
        uint256 amountInL = 308e18;
        uint256 amountInR = 610e18;
        amountIn = bound(amountIn, amountInL + 1, amountInR - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 2000e18, true));
        (, uint256 amountOutL,) = swapVM.quote(order, amountInL, _buildTakerData(order, true));
        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 amountOutR,) = swapVM.quote(order, amountInR, _buildTakerData(order, true));

        uint256 priceL = amountInL * ONE / amountOutL;
        uint256 price = amountIn * ONE / amountOut;
        uint256 priceR = amountInR * ONE / amountOutR;
        uint256 expectedPrice = ((amountIn - amountInL) * priceR + (amountInR - amountIn) * priceL) / (amountInR - amountInL);

        assertApproxEqAbs(price, expectedPrice, 2);

        (uint256 exactOutAmountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        uint256 exactOutPrice = exactOutAmountIn * ONE / amountOut;
        uint256 expectedExactOutPrice =
            ((exactOutAmountIn - amountInL) * priceR + (amountInR - exactOutAmountIn) * priceL) / (amountInR - amountInL);

        assertApproxEqAbs(exactOutPrice, expectedExactOutPrice, 2);
    }

    function testFuzz_FillGridAdjusterBalanceOut_PriceIsLinearByAmountIn(uint256 amountIn) public view {
        uint256 amountInL = 610e18;
        uint256 amountInR = 1040e18;
        amountIn = bound(amountIn, amountInL + 1, amountInR - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1500e18, 3000e18, false));
        (, uint256 amountOutL,) = swapVM.quote(order, amountInL, _buildTakerData(order, true));
        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 amountOutR,) = swapVM.quote(order, amountInR, _buildTakerData(order, true));

        uint256 priceL = amountInL * ONE / amountOutL;
        uint256 price = amountIn * ONE / amountOut;
        uint256 priceR = amountInR * ONE / amountOutR;
        uint256 expectedPrice = ((amountIn - amountInL) * priceR + (amountInR - amountIn) * priceL) / (amountInR - amountInL);

        assertApproxEqAbs(price, expectedPrice, 2);

        (uint256 exactOutAmountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        uint256 exactOutPrice = exactOutAmountIn * ONE / amountOut;
        uint256 expectedExactOutPrice =
            ((exactOutAmountIn - amountInL) * priceR + (amountInR - exactOutAmountIn) * priceL) / (amountInR - amountInL);

        assertApproxEqAbs(exactOutPrice, expectedExactOutPrice, 2);
    }

    function testFuzz_FillGridAdjusterBalanceIn_ExactInAndExactOutQuotesMatch(
        uint256 amountIn,
        uint256 amountOut
    ) public view {
        amountIn = bound(amountIn, 1, 1000e18 - 1);
        amountOut = bound(amountOut, 1, 2000e18 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1000e18, 2000e18, true));
        bytes memory exactInData = _buildTakerData(order, true);
        bytes memory exactOutData = _buildTakerData(order, false);

        (, uint256 quotedAmountOut,) = swapVM.quote(order, amountIn, exactInData);
        (uint256 roundTripAmountIn,,) = swapVM.quote(order, quotedAmountOut, exactOutData);
        assertApproxEqAbs(roundTripAmountIn, amountIn, 1);

        (uint256 quotedAmountIn,,) = swapVM.quote(order, amountOut, exactOutData);
        (, uint256 roundTripAmountOut,) = swapVM.quote(order, quotedAmountIn, exactInData);
        assertApproxEqAbs(roundTripAmountOut, amountOut, 2);
    }

    function testFuzz_FillGridAdjusterBalanceOut_ExactInAndExactOutQuotesMatch(
        uint256 amountIn,
        uint256 amountOut
    ) public view {
        amountIn = bound(amountIn, 1, 1500e18 - 1);
        amountOut = bound(amountOut, 1, 2000e18 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(1500e18, 3000e18, false));
        bytes memory exactInData = _buildTakerData(order, true);
        bytes memory exactOutData = _buildTakerData(order, false);

        (, uint256 quotedAmountOut,) = swapVM.quote(order, amountIn, exactInData);
        (uint256 roundTripAmountIn,,) = swapVM.quote(order, quotedAmountOut, exactOutData);
        assertApproxEqAbs(roundTripAmountIn, amountIn, 1);

        (uint256 quotedAmountIn,,) = swapVM.quote(order, amountOut, exactOutData);
        (, uint256 roundTripAmountOut,) = swapVM.quote(order, quotedAmountIn, exactInData);
        assertApproxEqAbs(roundTripAmountOut, amountOut, 2);
    }

    function test_FillGridAdjusterBalanceInAndOut_ShareGridPointPrices() public view {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 2000e18;
        uint256 surcharge = balanceIn / 2;
        uint256 surchargedBalanceIn = balanceIn + surcharge;

        ISwapVM.Order memory balanceInOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, true));
        ISwapVM.Order memory balanceOutOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, false));
        bytes memory balanceInData = _buildTakerData(balanceInOrder, true);
        bytes memory balanceOutData = _buildTakerData(balanceOutOrder, true);
        (uint24[] memory fillBps, uint24[] memory adjustBps) = _grid();

        for (uint256 i = 1; i < fillBps.length; i++) {
            uint256 adjustedBalanceIn = surchargedBalanceIn + surcharge * adjustBps[i] / BPS;
            uint256 balanceInCurveAmount = uint256(fillBps[i]) * adjustedBalanceIn / BPS;
            uint256 balanceOutCurveAmount = uint256(fillBps[i]) * balanceIn / BPS;

            (, uint256 balanceInCurveOutput,) = swapVM.quote(balanceInOrder, balanceInCurveAmount, balanceInData);
            (, uint256 balanceOutCurveOutput,) = swapVM.quote(balanceOutOrder, balanceOutCurveAmount, balanceOutData);

            uint256 balanceInCurvePrice = balanceInCurveAmount * ONE / balanceInCurveOutput;
            uint256 balanceOutCurvePrice = balanceOutCurveAmount * ONE / balanceOutCurveOutput;

            assertApproxEqAbs(balanceInCurvePrice, balanceOutCurvePrice, 1);
            assertGt(balanceInCurveAmount, balanceOutCurveAmount);
        }

        (, uint256 balanceInEndpointOutput,) = swapVM.quote(balanceInOrder, surchargedBalanceIn, balanceInData);
        (, uint256 balanceOutEndpointOutput,) = swapVM.quote(balanceOutOrder, balanceIn, balanceOutData);

        assertApproxEqAbs(
            surchargedBalanceIn * ONE / balanceInEndpointOutput,
            balanceIn * ONE / balanceOutEndpointOutput,
            1
        );
    }

    function testFuzz_FillGridAdjusterBalanceInAndOut_MatchPricesAtSameCurvePosition(
        uint24 interpolationSeed,
        uint8 segmentSeed
    ) public view {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 2000e18;
        uint256 surcharge = balanceIn / 2;
        uint256 surchargedBalanceIn = balanceIn + surcharge;

        ISwapVM.Order memory balanceInOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, true));
        ISwapVM.Order memory balanceOutOrder = _buildOrder(_buildProgram(balanceIn, balanceOut, false));
        (uint24[] memory fillBps, uint24[] memory adjustBps) = _grid();

        uint256 segment = bound(segmentSeed, 0, fillBps.length - 1);
        uint256 interpolationBps = bound(interpolationSeed, 1, BPS - 1);

        uint256 adjustedBalanceInL = surchargedBalanceIn + surcharge * adjustBps[segment] / BPS;
        uint256 balanceInCurveAmountL = uint256(fillBps[segment]) * adjustedBalanceInL / BPS;
        uint256 balanceOutCurveAmountL = uint256(fillBps[segment]) * balanceIn / BPS;

        uint256 balanceInCurveAmountR = surchargedBalanceIn;
        uint256 balanceOutCurveAmountR = balanceIn;
        if (segment + 1 < fillBps.length) {
            uint256 adjustedBalanceInR = surchargedBalanceIn + surcharge * adjustBps[segment + 1] / BPS;
            balanceInCurveAmountR = uint256(fillBps[segment + 1]) * adjustedBalanceInR / BPS;
            balanceOutCurveAmountR = uint256(fillBps[segment + 1]) * balanceIn / BPS;
        }

        uint256 balanceInCurveAmount = balanceInCurveAmountL + (balanceInCurveAmountR - balanceInCurveAmountL) * interpolationBps / BPS;
        uint256 balanceOutCurveAmount = balanceOutCurveAmountL + (balanceOutCurveAmountR - balanceOutCurveAmountL) * interpolationBps / BPS;

        (, uint256 balanceInCurveOutput,) = swapVM.quote(balanceInOrder, balanceInCurveAmount, _buildTakerData(balanceInOrder, true));
        (, uint256 balanceOutCurveOutput,) = swapVM.quote(balanceOutOrder, balanceOutCurveAmount, _buildTakerData(balanceOutOrder, true));

        assertApproxEqAbs(
            balanceInCurveAmount * balanceOutCurveOutput,
            balanceOutCurveAmount * balanceInCurveOutput,
            balanceInCurveAmount + balanceOutCurveAmount
        );
    }

    function buildFillGridAdjusterBalanceIn(
        uint24[] memory fillBps,
        uint24[] memory adjustBps
    ) external pure returns (bytes memory) {
        return FillGridAdjuster.build(true, fillBps, adjustBps);
    }

    function _buildProgram(uint256 balanceIn, uint256 balanceOut, bool adjustBalanceIn) private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = 1 << 23;
        scales[1] = 1 << 23;

        (uint24[] memory fillBps, uint24[] memory adjustBps) = _grid();

        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurcharge.build(adjustBalanceIn, uint40(block.timestamp), durations, scales),
            FillGridAdjuster.build(adjustBalanceIn, fillBps, adjustBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    function _grid() private pure returns (uint24[] memory fillBps, uint24[] memory adjustBps) {
        fillBps = new uint24[](4);
        adjustBps = new uint24[](4);

        fillBps[0] = 0;
        fillBps[1] = 0.2e7;
        fillBps[2] = 0.4e7;
        fillBps[3] = 0.7e7;

        adjustBps[0] = 0.1e7;
        adjustBps[1] = 0.08e7;
        adjustBps[2] = 0.05e7;
        adjustBps[3] = 0.04e7;
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(
            TraitsHelper.MakerTraitsLibArgs({
                maker: maker,
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: false,
                usePermit2: false,
                allowZeroAmountIn: true,
                program: program
            })
        );
    }

    function _buildTakerData(ISwapVM.Order memory order, bool exactIn) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));

        return orders.TakerTraitsLibBuild(
            TraitsHelper.TakerTraitsLibArgs({
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
            })
        );
    }
}
