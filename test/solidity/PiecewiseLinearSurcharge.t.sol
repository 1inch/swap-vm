// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test, console } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { LimitSwapVMRouterDebug } from "../../contracts/routers/LimitSwapVMRouterDebug.sol";
import { LimitOpcodesDebug } from "../../contracts/opcodes/LimitOpcodesDebug.sol";

import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { Time } from "../../contracts/libs/Time.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import {
    PiecewiseLinearSurcharge,
    PiecewiseLinearSurchargeBalanceIn,
    PiecewiseLinearSurchargeBalanceOut
} from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";

/// @title PiecewiseLinearSurcharge tests
contract PiecewiseLinearSurchargeTest is Test, LimitOpcodesDebug {
    using Math for uint256;

    Aqua public immutable aqua;
    LimitSwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    address public maker = address(0xBEEF);

    // Upper bound for fuzzed order/swap amounts
    // 18 decimals 100 * 10 ** 12, feels reasonable
    uint256 internal constant MAX_AMOUNT = 1e18 * 1e12 * 100;
    uint256 internal constant MAKER_PRIVATE_KEY = 0xBEEF;

    function setUp() public {
        swapVM = new LimitSwapVMRouterDebug(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    /// @dev staticBalances -> piecewise bump on balanceIn -> limit swap
    function _buildProgram(
        uint256 balanceIn,
        uint256 balanceOut,
        uint40 timestamp,
        uint16[] memory durations,
        uint24[] memory scales,
        bool scaleIn
    ) internal view returns (bytes memory) {
        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            scaleIn
                ? PiecewiseLinearSurchargeBalanceIn.build(timestamp, durations, scales)
                : PiecewiseLinearSurchargeBalanceOut.build(timestamp, durations, scales),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    /// @dev Maker has a limited `makingAmount` of `tokenB` and wishes to sell it for at least `takingAmount` of `tokenA`
    function testFuzz_PiecewiseLinearSurcharge_DutchExample_MakerExactSell(
        uint256 makingAmount,
        uint256 takingAmount,
        uint8 pointsCountSeed,
        uint32 timestampSeed,
        uint24[17] memory scaleSeed,
        uint16[16] memory durationSeed
    ) public {
        makingAmount = bound(makingAmount, 2, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 2, MAX_AMOUNT);

        uint256 pointsCount = bound(pointsCountSeed, 2, 17);
        uint24[] memory scales = new uint24[](pointsCount);
        uint16[] memory durations = new uint16[](pointsCount - 1);

        uint40 timestamp = timestampSeed;
        uint256 last = pointsCount - 1;

        scales[0] = scaleSeed[0];
        for (uint256 i = 1; i < pointsCount; i++) {
            scales[i] = uint24(bound(scaleSeed[i], 0, uint256(scales[i - 1]))); // Descending scales
            durations[i - 1] = uint16(bound(durationSeed[i - 1], 1, type(uint16).max)); // Non-zero durations
        }
        scales[last] = 0;

        ISwapVM.Order memory order = _buildOrder(_buildProgram(takingAmount, makingAmount, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;

        uint256 surcharge = PiecewiseLinearSurchargeBalanceIn.scaleValue(takingAmount, scales[0]);

        // At the initial point the whole `makingAmount` sells for exactly `takingAmount + surcharge`, and one wei less in buys strictly less
        vm.warp(timestamp);
        (, amountOut,) = swapVM.quote(order, takingAmount + surcharge, takerDataExactIn);
        assertEq(amountOut, makingAmount);
        (, amountOut,) = swapVM.quote(order, takingAmount + surcharge - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the initial point the whole `makingAmount` buys for exactly `takingAmount + surcharge`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, makingAmount, takerDataExactOut);
        assertEq(amountIn, takingAmount + surcharge);
        (amountIn,,) = swapVM.quote(order, makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount + surcharge);

        // At the final point the whole `makingAmount` sells for exactly `takingAmount`, and one wei less in buys strictly less
        vm.warp(timestamp + _sum(durations, last));
        (, amountOut,) = swapVM.quote(order, takingAmount, takerDataExactIn);
        assertEq(amountOut, makingAmount);
        (, amountOut,) = swapVM.quote(order, takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the final point the whole `makingAmount` buys for exactly `takingAmount`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, makingAmount, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        for (uint256 k = 1; k < pointsCount; k++) {
            vm.warp(timestamp + _sum(durations, k - 1));
            (uint256 amountInPast,,) = swapVM.quote(order, makingAmount, takerDataExactOut);

            // Predictable at exact point
            vm.warp(timestamp + _sum(durations, k));
            (uint256 amountInNext,,) = swapVM.quote(order, makingAmount, takerDataExactOut);
            assertEq(amountInNext, takingAmount + PiecewiseLinearSurchargeBalanceIn.scaleValue(takingAmount, scales[k]));

            // Mid point
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k)) / 2);
            (uint256 amountInMidLeft,,) = swapVM.quote(order, makingAmount, takerDataExactOut);
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k) + 1) / 2);
            (uint256 amountInMidRight,,) = swapVM.quote(order, makingAmount, takerDataExactOut);

            uint256 midExpected = (amountInPast + amountInNext) / 2;
            uint256 midFactual = (amountInMidLeft + amountInMidRight) / 2;
            assertApproxEqAbs(midExpected, midFactual, takingAmount.ceilDiv(1 << 24));
        }
    }

    /// @dev Maker want exact `takingAmount` of `tokenA` and ready to pay at most `makingAmount` of `tokenB`
    function testFuzz_PiecewiseLinearSurcharge_DutchExample_MakerExactBuy(
        uint256 makingAmount,
        uint256 takingAmount,
        uint8 pointsCountSeed,
        uint32 timestampSeed,
        uint24[17] memory scaleSeed,
        uint16[16] memory durationSeed
    ) public {
        makingAmount = bound(makingAmount, 2, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 2, MAX_AMOUNT);

        uint256 pointsCount = bound(pointsCountSeed, 2, 17);
        uint24[] memory scales = new uint24[](pointsCount);
        uint16[] memory durations = new uint16[](pointsCount - 1);

        uint40 timestamp = timestampSeed;
        uint256 last = pointsCount - 1;

        scales[0] = scaleSeed[0];
        for (uint256 i = 1; i < pointsCount; i++) {
            scales[i] = uint24(bound(scaleSeed[i], 0, uint256(scales[i - 1]))); // Descending scales
            durations[i - 1] = uint16(bound(durationSeed[i - 1], 1, type(uint16).max)); // Non-zero durations
        }
        scales[last] = 0;

        ISwapVM.Order memory order = _buildOrder(_buildProgram(takingAmount, makingAmount, timestamp, durations, scales, false));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;
        uint256 surcharge = PiecewiseLinearSurchargeBalanceOut.scaleValue(makingAmount, scales[0]);

        // At the initial point the whole `takingAmount` sells for exactly `makingAmount - surcharge`, and one wei less in sells strictly less
        vm.warp(timestamp);
        (, amountOut,) = swapVM.quote(order, takingAmount, takerDataExactIn);
        assertEq(amountOut, makingAmount - surcharge);
        (, amountOut,) = swapVM.quote(order, takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount - surcharge);

        // At the initial point the whole `takingAmount` buys for exactly `makingAmount - surcharge`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, makingAmount - surcharge, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, makingAmount - surcharge - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        // At the final point the whole `takingAmount` sells for exactly `makingAmount`, and one wei less in sells strictly less
        vm.warp(timestamp + _sum(durations, last));
        (, amountOut,) = swapVM.quote(order, takingAmount, takerDataExactIn);
        assertEq(amountOut, makingAmount);

        (, amountOut,) = swapVM.quote(order, takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the final point the whole `makingAmount` buys for exactly `takingAmount`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, makingAmount, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        for (uint256 k = 1; k < pointsCount; k++) {
            vm.warp(timestamp + _sum(durations, k - 1));
            (uint256 amountInPast,,) = swapVM.quote(order, makingAmount - surcharge, takerDataExactOut);

            // Predictable at exact point
            vm.warp(timestamp + _sum(durations, k));
            (,uint256 amountOutNext,) = swapVM.quote(order, takingAmount, takerDataExactIn);
            assertEq(amountOutNext, makingAmount - PiecewiseLinearSurchargeBalanceOut.scaleValue(makingAmount, scales[k]));
            (uint256 amountInNext,,) = swapVM.quote(order, makingAmount - surcharge, takerDataExactOut);

            // Mid point
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k)) / 2);
            (uint256 amountInMidLeft,,) = swapVM.quote(order, makingAmount - surcharge, takerDataExactOut);
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k) + 1) / 2);
            (uint256 amountInMidRight,,) = swapVM.quote(order, makingAmount - surcharge, takerDataExactOut);

            uint256 midExpected = (amountInPast + amountInNext) / 2;
            uint256 midFactual = (amountInMidLeft + amountInMidRight) / 2;
            assertApproxEqAbs(midExpected, midFactual, takingAmount.ceilDiv(1 << 24) + takingAmount.ceilDiv(makingAmount - surcharge));
        }
    }

    function testFuzz_PiecewiseLinearSurcharge_InAndOutQuotesMatch(uint256 balanceIn, uint256 balanceOut) public {
        balanceIn = bound(balanceIn, 4, MAX_AMOUNT);
        balanceOut = bound(balanceOut, 4, MAX_AMOUNT);
        uint40 timestamp = 1000;

        uint16[] memory durations = new uint16[](2);
        durations[0] = 100;
        durations[1] = 100;

        uint24[] memory scales = new uint24[](3);
        scales[0] = uint24(1 << 22);
        scales[1] = uint24(uint256(10) * (1 << 24) / 100);
        scales[2] = 0;

        ISwapVM.Order memory orderIn = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        ISwapVM.Order memory orderOut = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, false));

        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256[7] memory offsets = [uint256(0), 12, 13, 25, 100, 175, 200];
        for (uint256 i; i < offsets.length; i++) {
            vm.warp(uint256(timestamp) + offsets[i]);

            (uint256 amountInFromInOrder,,) = swapVM.quote(orderIn, balanceOut / 2, takerDataExactOut);
            (uint256 amountInFromOutOrder,,) = swapVM.quote(orderOut, balanceOut / 2, takerDataExactOut);

            (,uint256 amountOutFromInOrder,) = swapVM.quote(orderIn, balanceIn / 2, takerDataExactIn);
            (,uint256 amountOutFromOutOrder,) = swapVM.quote(orderOut, balanceIn / 2, takerDataExactIn);

            assertApproxEqAbs(amountInFromInOrder, amountInFromOutOrder, balanceIn.ceilDiv(balanceOut));
            assertApproxEqAbs(amountOutFromInOrder, amountOutFromOutOrder, balanceOut.ceilDiv(balanceIn));
        }
    }

    function test_PiecewiseLinearSurchargeBalanceIn_RelativeToOrderAnnouncement() public {
        uint40 announcedAt = 1_000_000;
        maker = vm.addr(MAKER_PRIVATE_KEY);
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 100;
        scales[0] = type(uint24).max;
        scales[1] = uint24(2 ** 23);

        ISwapVM.Order memory order = _buildOrder(
            _buildProgram(4e18, 4e18, Time.RELATIVE_TIME_FLAG, durations, scales, true)
        );
        bytes memory takerData = _buildTakerData(true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));
        takerData = bytes.concat(takerData, abi.encodePacked(r, s, v));

        tokenA.mint(address(this), 3e18);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.mint(maker, 3e18);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.warp(announcedAt);
        (, uint256 amountOut,) = swapVM.swap(order, 3e18, takerData);
        assertEq(amountOut, 1_500_000_044_703_484_913);

        vm.warp(announcedAt + 50);
        (, amountOut,) = swapVM.quote(order, 3e18, takerData);
        assertEq(amountOut, 1_714_285_772_673_939_727);
    }

    function test_PiecewiseLinearSurchargeBalanceOut_RelativeToOrderAnnouncement() public {
        uint40 announcedAt = 1_000_000;
        maker = vm.addr(MAKER_PRIVATE_KEY);
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 100;
        scales[0] = type(uint24).max;
        scales[1] = uint24(2 ** 23);

        ISwapVM.Order memory order = _buildOrder(
            _buildProgram(4e18, 4e18, Time.RELATIVE_TIME_FLAG, durations, scales, false)
        );
        bytes memory takerData = _buildTakerData(true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));
        takerData = bytes.concat(takerData, abi.encodePacked(r, s, v));

        tokenA.mint(address(this), 4e18);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.mint(maker, 3e18);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.warp(announcedAt);
        (, uint256 amountOut,) = swapVM.swap(order, 4e18, takerData);
        assertEq(amountOut, 2_000_000_059_604_646_552);

        vm.warp(announcedAt + 50);
        (, amountOut,) = swapVM.quote(order, 4e18, takerData);
        assertEq(amountOut, 2_285_714_363_565_252_971);
    }

    function test_PiecewiseLinearSurcharge_GasBenchmark() public {
        // Warmup account
        address(swapVM).staticcall("");

        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        for (uint256 length = 2; length < 51; ++length) {
            uint16[] memory durations = new uint16[](length - 1);
            uint24[] memory scales = new uint24[](length);

            uint40 timestamp = 50;
            for (uint256 i = 0; i < length; ++i) {
                scales[i] = type(uint24).max;
            }
            for (uint256 i = 1; i < length; ++i) {
                durations[i - 1] = 100;
            }

            ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
            bytes memory takerDataExactIn = _buildTakerData(true);

            uint256 amountIn = 10_000_000;

            uint256 usage;
            uint256 worst;

            for (uint256 i = 0; i <= length; ++i) {
                vm.warp(i * 100);
                uint256 gas = gasleft();
                swapVM.quote(order, amountIn, takerDataExactIn);
                uint256 temp = gas - gasleft();
                usage += temp;
                if (worst < temp) worst = temp;
            }

            console.log(usage / (length + 1), worst, length);
        }
    }

    function test_PiecewiseLinearSurcharge_Basic() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint16[] memory durations = new uint16[](5);
        uint24[] memory scales = new uint24[](6);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 100;  scales[1] = uint24(2 ** 23);
            durations[1] = 200;  scales[2] = uint24(2 ** 20 * 5);
            durations[2] = 100;  scales[3] = uint24(2 ** 22);
            durations[3] = 0;    scales[4] = uint24(2 ** 21);
            durations[4] = 100;  scales[5] = uint24(2 ** 20 * 3);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_050_126);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_874_998);
        }
        {
            vm.warp(1050);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 22_857_143);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 43_749_999);
        }
        {
            vm.warp(1100);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
        {
            vm.warp(1101);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_683_344);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_476_562);
        }
        {
            vm.warp(1270);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 29_836_830);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 33_515_625);
        }
        {
            vm.warp(1300);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 30_476_190);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 32_812_500);
        }
        {
            vm.warp(1301);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 30_490_710);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 32_796_875);
        }
        {
            vm.warp(1350);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 31_219_512);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 32_031_250);
        }
        {
            vm.warp(1400);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
        {
            vm.warp(1425);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 35_068_493);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_515_625);
        }
        {
            vm.warp(1450);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 34_594_594);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_906_250);
        }
        {
            vm.warp(1500);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 33_684_210);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 29_687_500);
        }
        {
            vm.warp(1501);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 33_684_210);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 29_687_500);
        }
        {
            vm.warp(100_000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 33_684_210);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 29_687_500);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_Single() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_Double() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23);
            durations[1] = 0;    scales[2] = uint24(2 ** 22);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_SingleWrapped() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](3);
        uint24[] memory scales = new uint24[](4);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23);
            durations[1] = 0;    scales[2] = uint24(2 ** 22);
            durations[2] = 2;    scales[3] = uint24(2 ** 21);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 22_857_143);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 43_749_999);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 33_684_210);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 29_687_500);
        }
        {
            vm.warp(1004);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 35_555_555);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_125_000);
        }
        {
            vm.warp(1005);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 35_555_555);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_125_000);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_DoubleWrapped() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](4);
        uint24[] memory scales = new uint24[](5);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23);
            durations[1] = 0;    scales[2] = uint24(2 ** 21 * 3);
            durations[2] = 0;    scales[3] = uint24(2 ** 22);
            durations[3] = 2;    scales[4] = uint24(2 ** 21);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 22_857_143);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 43_749_999);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 33_684_210);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 29_687_500);
        }
        {
            vm.warp(1004);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 35_555_555);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_125_000);
        }
        {
            vm.warp(1005);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 35_555_555);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 28_125_000);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_SingleFirst() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23);
            durations[1] = 2;    scales[2] = uint24(2 ** 22);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 29_090_909);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 34_375_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
    }

    function test_PiecewiseLinearSurcharge_ZeroDuration_SingleLast() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23);
            durations[1] = 0;    scales[2] = uint24(2 ** 22);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 20_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 49_999_999);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 22_857_143);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 43_749_999);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 26_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 37_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 32_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, amountOut, takerDataExactOut);
            assertEq(amountInCalc, 31_250_000);
        }
    }

    function _sum(uint16[] memory durations, uint256 n) internal pure returns (uint40 sum) {
        for (uint256 i; i < n; ++i) {
            sum += durations[i];
        }
    }

    function _buildOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
        }));
    }

    function _buildTakerData(bool exactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
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
            signature: ""
        }));
    }
}
