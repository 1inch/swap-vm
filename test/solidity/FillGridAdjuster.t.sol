// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";

import {ISwapVM} from "../../contracts/interfaces/ISwapVM.sol";
import {LimitSwapVMRouterDebug} from "../../contracts/routers/LimitSwapVMRouterDebug.sol";
import {LimitOpcodesDebug} from "../../contracts/opcodes/LimitOpcodesDebug.sol";
import {MakerTraitsLib} from "../../contracts/libs/MakerTraits.sol";
import {TakerTraitsLib} from "../../contracts/libs/TakerTraits.sol";
import {StaticBalances} from "../../contracts/instructions/Balances.sol";
import {InvalidateTokenIn, InvalidateTokenOut} from "../../contracts/instructions/Invalidators.sol";
import {
    PiecewiseLinearSurchargeBalanceIn,
    PiecewiseLinearSurchargeBalanceOut
} from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import {
    FillGridStepwiseAdjusterBalanceIn,
    FillGridStepwiseAdjusterBalanceOut
} from "../../contracts/instructions/FillGridAdjuster.sol";
import {LimitSwap} from "../../contracts/instructions/LimitSwap.sol";

contract FillGridAdjusterTest is Test, LimitOpcodesDebug {
    Aqua public immutable aqua;
    LimitSwapVMRouterDebug public swapVM;
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
        swapVM = new LimitSwapVMRouterDebug(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
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

    function test_FillGridStepwiseAdjusterBalanceIn_ExactOut_Basic() public {
        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        (uint256 amountIn95,,) = swapVM.quote(order, 950e18, takerData);
        (uint256 amountIn5,,) = swapVM.quote(order, 50e18, takerData);

        assertEq(amountIn95, 1377.5e18);
        assertEq(amountIn5, 75e18);
    }

    function test_FillGridStepwiseAdjusterBalanceOut_ExactIn_Basic() public {
        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        (, uint256 amountOut95,) = swapVM.quote(order, 950e18, takerData);
        (, uint256 amountOut5,) = swapVM.quote(order, 50e18, takerData);

        assertEq(amountOut95, 997.5e18);
        assertEq(amountOut5, 50e18);
    }

    function test_FillGridStepwiseAdjusterBalanceIn_ExactOut_PointBoundaries() public {
        uint256[5] memory amountsOut = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];
        uint256[5] memory expectedAmountsIn = [uint256(149e18), 444e18, 735e18, 1022e18, 1305e18];

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        for (uint256 i; i < amountsOut.length; i++) {
            (uint256 amountIn,,) = swapVM.quote(order, amountsOut[i], takerData);
            assertEq(amountIn, expectedAmountsIn[i]);
        }
    }

    function test_FillGridStepwiseAdjusterBalanceIn_ExactIn_PointBoundaries() public {
        uint256[5] memory amountsIn = [uint256(149e18), 444e18, 735e18, 1022e18, 1305e18];
        uint256[5] memory expectedAmountsOut = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        for (uint256 i; i < amountsIn.length; i++) {
            (, uint256 amountOut,) = swapVM.quote(order, amountsIn[i], takerData);
            assertEq(amountOut, expectedAmountsOut[i]);
        }
    }

    function test_FillGridStepwiseAdjusterBalanceOut_ExactIn_PointBoundaries() public {
        uint256[5] memory amountsIn = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];
        uint256[5] memory expectedAmountsOut = [uint256(101e18), 306e18, 515e18, 728e18, 945e18];

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, true);

        for (uint256 i; i < amountsIn.length; i++) {
            (, uint256 amountOut,) = swapVM.quote(order, amountsIn[i], takerData);
            assertEq(amountOut, expectedAmountsOut[i]);
        }
    }

    function test_FillGridStepwiseAdjusterBalanceOut_ExactOut_PointBoundaries() public {
        uint256[5] memory amountsOut = [uint256(101e18), 306e18, 515e18, 728e18, 945e18];
        uint256[5] memory expectedAmountsIn = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        bytes memory takerData = _buildTakerData(order, false);

        for (uint256 i; i < amountsOut.length; i++) {
            (uint256 amountIn,,) = swapVM.quote(order, amountsOut[i], takerData);
            assertEq(amountIn, expectedAmountsIn[i]);
        }
    }

    function test_FillGridStepwiseAdjuster_ZeroAdjustment() public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);

        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        uint24[] memory fillBps = new uint24[](1);
        uint24[] memory adjustBps = new uint24[](1);

        ISwapVM.Order memory balanceInOrder = _buildOrder(
            bytes.concat(
                StaticBalances.build(balanceIn, balanceOut),
                PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales),
                FillGridStepwiseAdjusterBalanceIn.build(fillBps, adjustBps),
                LimitSwap.build(address(tokenA), address(tokenB))
            )
        );
        ISwapVM.Order memory balanceOutOrder = _buildOrder(
            bytes.concat(
                StaticBalances.build(balanceIn, balanceOut),
                PiecewiseLinearSurchargeBalanceOut.build(uint40(block.timestamp), durations, scales),
                FillGridStepwiseAdjusterBalanceOut.build(fillBps, adjustBps),
                LimitSwap.build(address(tokenA), address(tokenB))
            )
        );

        (uint256 quotedIn,,) = swapVM.quote(balanceInOrder, 50e18, _buildTakerData(balanceInOrder, false));
        (, uint256 quotedOut,) = swapVM.quote(balanceOutOrder, 50e18, _buildTakerData(balanceOutOrder, true));

        assertEq(quotedIn, 50e18);
        assertEq(quotedOut, 50e18);
    }

    function test_FillGridStepwiseAdjuster_NoMatchingPoint() public {
        ISwapVM.Order memory balanceInOrder =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory balanceOutOrder =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));

        (, uint256 quotedOut,) = swapVM.quote(balanceInOrder, 75e18, _buildTakerData(balanceInOrder, true));
        (uint256 quotedIn,,) = swapVM.quote(balanceOutOrder, 50e18, _buildTakerData(balanceOutOrder, false));

        assertEq(quotedOut, 50e18);
        assertEq(quotedIn, 50e18);
    }

    function testFuzz_FillGridStepwiseAdjusterBalanceIn_ExactIn_MatchesReference(uint256 amountSeed, uint8 pointSeed)
        public
    {
        uint256[5] memory minAmountsIn = [uint256(149e18), 444e18, 735e18, 1022e18, 1305e18];
        uint256[5] memory upperBounds = [uint256(444e18), 735e18, 1022e18, 1305e18, 1450e18];
        uint256[5] memory referenceBalancesIn = [uint256(1490e18), 1480e18, 1470e18, 1460e18, 1450e18];
        uint256 point = bound(pointSeed, 0, 4);
        uint256 amountIn = minAmountsIn[point] + amountSeed % (upperBounds[point] - minAmountsIn[point]);

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder =
            _buildOrder(_buildReferenceProgram(referenceBalancesIn[point], 1000e18));

        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 referenceAmountOut,) = swapVM.quote(referenceOrder, amountIn, _buildTakerData(referenceOrder, true));

        assertEq(amountOut, referenceAmountOut);
    }

    function testFuzz_FillGridStepwiseAdjusterBalanceIn_ExactOut_MatchesReference(uint256 amountSeed, uint8 pointSeed)
        public
    {
        uint256[5] memory minAmountsOut = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];
        uint256[5] memory upperBounds = [uint256(300e18), 500e18, 700e18, 900e18, 1000e18];
        uint256[5] memory referenceBalancesIn = [uint256(1490e18), 1480e18, 1470e18, 1460e18, 1450e18];
        uint256 point = bound(pointSeed, 0, 4);
        uint256 amountOut = minAmountsOut[point] + amountSeed % (upperBounds[point] - minAmountsOut[point]);

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1000e18, 1 << 23, true, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder =
            _buildOrder(_buildReferenceProgram(referenceBalancesIn[point], 1000e18));

        (uint256 amountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        (uint256 referenceAmountIn,,) = swapVM.quote(referenceOrder, amountOut, _buildTakerData(referenceOrder, false));

        assertEq(amountIn, referenceAmountIn);
    }

    function testFuzz_FillGridStepwiseAdjusterBalanceOut_ExactIn_MatchesReference(uint256 amountSeed, uint8 pointSeed)
        public
    {
        uint256[5] memory minAmountsIn = [uint256(100e18), 300e18, 500e18, 700e18, 900e18];
        uint256[5] memory upperBounds = [uint256(300e18), 500e18, 700e18, 900e18, 1000e18];
        uint256[5] memory referenceBalancesOut = [uint256(1010e18), 1020e18, 1030e18, 1040e18, 1050e18];
        uint256 point = bound(pointSeed, 0, 4);
        uint256 amountIn = minAmountsIn[point] + amountSeed % (upperBounds[point] - minAmountsIn[point]);

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder =
            _buildOrder(_buildReferenceProgram(1000e18, referenceBalancesOut[point]));

        (, uint256 amountOut,) = swapVM.quote(order, amountIn, _buildTakerData(order, true));
        (, uint256 referenceAmountOut,) = swapVM.quote(referenceOrder, amountIn, _buildTakerData(referenceOrder, true));

        assertEq(amountOut, referenceAmountOut);
    }

    function testFuzz_FillGridStepwiseAdjusterBalanceOut_ExactOut_MatchesReference(uint256 amountSeed, uint8 pointSeed)
        public
    {
        uint256[5] memory minAmountsOut = [uint256(101e18), 306e18, 515e18, 728e18, 945e18];
        uint256[5] memory upperBounds = [uint256(306e18), 515e18, 728e18, 945e18, 1050e18];
        uint256[5] memory referenceBalancesOut = [uint256(1010e18), 1020e18, 1030e18, 1040e18, 1050e18];
        uint256 point = bound(pointSeed, 0, 4);
        uint256 amountOut = minAmountsOut[point] + amountSeed % (upperBounds[point] - minAmountsOut[point]);

        ISwapVM.Order memory order =
            _buildOrder(_buildProgram(1000e18, 1500e18, 1 << 23, false, InvalidationScope.Total));
        ISwapVM.Order memory referenceOrder =
            _buildOrder(_buildReferenceProgram(1000e18, referenceBalancesOut[point]));

        (uint256 amountIn,,) = swapVM.quote(order, amountOut, _buildTakerData(order, false));
        (uint256 referenceAmountIn,,) = swapVM.quote(referenceOrder, amountOut, _buildTakerData(referenceOrder, false));

        assertEq(amountIn, referenceAmountIn);
    }

    function testFuzz_FillGridStepwiseAdjusterBalanceIn_TotalVsRemainingVolume(
        uint24 surchargeScaleSeed,
        uint8 firstFillPercentSeed
    ) public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24(bound(surchargeScaleSeed, 1, type(uint24).max));
        uint256 firstAmountOut = balanceOut * bound(firstFillPercentSeed, 1, 9) / 100;
        uint256 remainingOut = balanceOut - firstAmountOut;
        uint256 secondAmountOut = remainingOut / 2;

        ISwapVM.Order memory totalOrder =
            _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, true, InvalidationScope.Total));
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

    function testFuzz_FillGridStepwiseAdjusterBalanceOut_TotalVsRemainingVolume(
        uint24 surchargeScaleSeed,
        uint8 firstFillPercentSeed
    ) public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24(bound(surchargeScaleSeed, 1, type(uint24).max));
        uint256 firstAmountIn = balanceIn * bound(firstFillPercentSeed, 1, 9) / 100;
        uint256 remainingIn = balanceIn - firstAmountIn;
        uint256 secondAmountIn = remainingIn / 2;

        ISwapVM.Order memory totalOrder =
            _buildOrder(_buildProgram(balanceIn, balanceOut, surchargeScale, false, InvalidationScope.Total));
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

    function test_FillGridStepwiseAdjusterBalanceIn_ContextOverflow() public {
        uint256 max = type(uint232).max;

        ISwapVM.Order memory exactInOrder =
            _buildOrder(_buildProgram(max + 1, 100e18, 0, true, InvalidationScope.Total));
        bytes memory exactInData = _buildTakerData(exactInOrder, true);
        vm.expectRevert(FillGridStepwiseAdjusterBalanceIn.FillGridStepwiseAdjusterContextOverflow.selector);
        swapVM.quote(exactInOrder, 1, exactInData);

        ISwapVM.Order memory exactOutOrder =
            _buildOrder(_buildProgram(100e18, max + 1, 0, true, InvalidationScope.Total));
        bytes memory exactOutData = _buildTakerData(exactOutOrder, false);
        vm.expectRevert(FillGridStepwiseAdjusterBalanceIn.FillGridStepwiseAdjusterContextOverflow.selector);
        swapVM.quote(exactOutOrder, 1, exactOutData);
    }

    function test_FillGridStepwiseAdjusterBalanceOut_ContextOverflow() public {
        uint256 max = type(uint232).max;

        ISwapVM.Order memory exactInOrder =
            _buildOrder(_buildProgram(max + 1, 100e18, 0, false, InvalidationScope.Total));
        bytes memory exactInData = _buildTakerData(exactInOrder, true);
        vm.expectRevert(FillGridStepwiseAdjusterBalanceOut.FillGridStepwiseAdjusterContextOverflow.selector);
        swapVM.quote(exactInOrder, 1, exactInData);

        ISwapVM.Order memory exactOutOrder =
            _buildOrder(_buildProgram(100e18, max + 1, 0, false, InvalidationScope.Total));
        bytes memory exactOutData = _buildTakerData(exactOutOrder, false);
        vm.expectRevert(FillGridStepwiseAdjusterBalanceOut.FillGridStepwiseAdjusterContextOverflow.selector);
        swapVM.quote(exactOutOrder, 1, exactOutData);
    }

    function _grid() private pure returns (uint24[] memory fillBps, uint24[] memory adjustBps) {
        fillBps = new uint24[](5);
        adjustBps = new uint24[](5);
        fillBps[0] = 0.1e7; adjustBps[0] = 0.98e7;
        fillBps[1] = 0.3e7; adjustBps[1] = 0.96e7;
        fillBps[2] = 0.5e7; adjustBps[2] = 0.94e7;
        fillBps[3] = 0.7e7; adjustBps[3] = 0.92e7;
        fillBps[4] = 0.9e7; adjustBps[4] = 0.90e7;
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
            ? FillGridStepwiseAdjusterBalanceIn.build(fillBps, adjustBps)
            : FillGridStepwiseAdjusterBalanceOut.build(fillBps, adjustBps);
        bytes memory invalidator = scaleIn ? InvalidateTokenOut.build() : InvalidateTokenIn.build();
        bytes memory swap = LimitSwap.build(address(tokenA), address(tokenB));

        if (scope == InvalidationScope.Total) {
            return bytes.concat(balances, surcharge, adjuster, invalidator, swap);
        }
        return bytes.concat(balances, surcharge, invalidator, adjuster, swap);
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: false,
                usePermit2: false,
                allowZeroAmountIn: true,
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
            })
        );
    }

    function _buildReferenceProgram(uint256 balanceIn, uint256 balanceOut) private view returns (bytes memory) {
        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    function _buildTakerData(ISwapVM.Order memory order, bool exactIn) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));

        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(0),
                isExactIn: exactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: false,
                isAToB: true,
                allowPartialFill: true,
                usePermit2: false,
                threshold: "",
                to: address(this),
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
                signature: abi.encodePacked(r, s, v)
            })
        );
    }
}
