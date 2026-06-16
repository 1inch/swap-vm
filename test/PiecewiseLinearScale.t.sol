// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test, console } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouterDebug } from "../src/routers/LimitSwapVMRouterDebug.sol";
import { LimitOpcodesDebug } from "../src/opcodes/LimitOpcodesDebug.sol";

import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { PiecewiseLinearScaleArgsBuilder } from "../src/instructions/PiecewiseLinearScale.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @title PiecewiseLinearScale tests
contract PiecewiseLinearScaleTest is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    LimitSwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    address public maker = address(0xBEEF);

    // Upper bound for fuzzed order/swap amounts
    // 18 decimals 100 * 10 ** 12, feels reasonable
    uint256 internal constant MAX_AMOUNT = 1e18 * 1e12 * 100;

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        swapVM = new LimitSwapVMRouterDebug(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
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
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([balanceIn, balanceOut]))),
            scaleIn
                ? p.build(_piecewiseLinearScaleBalanceIn1D, PiecewiseLinearScaleArgsBuilder.build(timestamp, durations, scales))
                : p.build(_piecewiseLinearScaleBalanceOut1D, PiecewiseLinearScaleArgsBuilder.build(timestamp, durations, scales)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    /// @notice Unscale Verification
    /// @dev The `unscaleValue` MUST return the minimal value scaling which back would give the same scaled result
    function testFuzz_PiecewiseLinearScale_UnscaleValue(uint256 value, uint24 scale) public pure {
        value = bound(value, 0, type(uint232).max);

        uint256 unscaled = PiecewiseLinearScaleArgsBuilder.unscaleValue(value, scale);
        uint256 scaled = PiecewiseLinearScaleArgsBuilder.scaleValue(unscaled, scale);

        assertEq(scaled, value);

        if (unscaled > 0) {
            uint256 scaledLess = PiecewiseLinearScaleArgsBuilder.scaleValue(unscaled - 1, scale);
            assertLt(scaledLess, value);
        }
    }

    /// @notice Dutch auction via a descending piecewise-linear scale sample
    /// @dev Maker has a limited `makingAmount` of `tokenB` and wishes to sell it for at least `takingAmount` of `tokenA`
    function testFuzz_PiecewiseLinearScale_DutchExample_MakerExactIn(
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

        scales[0] = type(uint24).max; // Initial scale = 1.0
        for (uint256 i = 1; i < pointsCount; i++) {
            scales[i] = uint24(bound(scaleSeed[i], 0, uint256(scales[i - 1]))); // Descending scales
            durations[i - 1] = uint16(bound(durationSeed[i - 1], 1, type(uint16).max)); // Non-zero durations
        }

        // It is important that `balanceIn` is not `takingAmount` and should be calculated
        uint256 balanceIn = PiecewiseLinearScaleArgsBuilder.unscaleValue(takingAmount, scales[last]);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, makingAmount, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;

        // At the initial point the whole `makingAmount` sells for exactly `balanceIn`, and one wei less in buys strictly less
        vm.warp(timestamp);
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), balanceIn, takerDataExactIn);
        assertEq(amountOut, makingAmount);
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), balanceIn - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the initial point the whole `makingAmount` buys for exactly `balanceIn`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
        assertEq(amountIn, balanceIn);
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, balanceIn);

        // At the final point the whole `makingAmount` sells for exactly `takingAmount`, and one wei less in buys strictly less
        vm.warp(timestamp + _sum(durations, last));
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
        assertEq(amountOut, makingAmount);
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the final point the whole `makingAmount` buys for exactly `takingAmount`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        for (uint256 k = 1; k < pointsCount; k++) {
            vm.warp(timestamp + _sum(durations, k - 1));
            (uint256 amountInPast,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);

            // Predictable at exact point
            vm.warp(timestamp + _sum(durations, k));
            (uint256 amountInNext,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
            assertEq(amountInNext, PiecewiseLinearScaleArgsBuilder.scaleValue(balanceIn, scales[k]));

            // Mid point
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k)) / 2);
            (uint256 amountInMidLeft,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k) + 1) / 2);
            (uint256 amountInMidRight,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
            assertApproxEqAbs((amountInMidLeft + amountInMidRight) / 2, (amountInPast + amountInNext) / 2, (balanceIn >> 24) + 1);
        }
    }

    /// @notice Dutch auction via a ascending piecewise-linear scale sample
    /// @dev Maker want exact `takingAmount` of `tokenA` and ready to pay `makingAmount` of `tokenB` at max
    function testFuzz_PiecewiseLinearScale_DutchExample_MakerExactOut(
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

        // Initial scale set so that minimal balanceOut >= 2
        scales[0] = uint24(bound(scaleSeed[0], (2 * 2 ** 24 + makingAmount - 1) / makingAmount - 1, type(uint24).max));
        for (uint256 i = 1; i < pointsCount; i++) {
            scales[i] = uint24(bound(scaleSeed[i], uint256(scales[i - 1]), type(uint24).max)); // Ascending scales
            durations[i - 1] = uint16(bound(durationSeed[i - 1], 1, type(uint16).max)); // Non-zero durations
        }
        scales[last] = type(uint24).max; // Last scale = 1.0

        // Here `balanceOut = makingAmount` with last scale 1.0
        ISwapVM.Order memory order = _buildOrder(_buildProgram(takingAmount, makingAmount, timestamp, durations, scales, false));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;

        // The least `balanceOut` with the worst scale
        uint256 balanceOutInitial = PiecewiseLinearScaleArgsBuilder.scaleValue(makingAmount, scales[0]);

        // At the initial point the whole `takingAmount` sells for exactly `balanceOutInitial`, and one wei less in sells strictly less
        vm.warp(timestamp);
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
        assertEq(amountOut, balanceOutInitial);
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, balanceOutInitial);

        // At the initial point the whole `takingAmount` buys for exactly `balanceOutInitial`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), balanceOutInitial, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), balanceOutInitial - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        // At the final point the whole `takingAmount` sells for exactly `makingAmount`, and one wei less in sells strictly less
        vm.warp(timestamp + _sum(durations, last));
        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
        assertEq(amountOut, makingAmount);

        (, amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount - 1, takerDataExactIn);
        assertLt(amountOut, makingAmount);

        // At the final point the whole `makingAmount` buys for exactly `takingAmount`, and one wei less out requires less or equal in
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
        assertEq(amountIn, takingAmount);
        (amountIn,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount - 1, takerDataExactOut);
        assertLe(amountIn, takingAmount);

        for (uint256 k = 1; k < pointsCount; k++) {
            vm.warp(timestamp + _sum(durations, k - 1));
            (, uint256 amountOutPast,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);

            // Predictable at exact point
            vm.warp(timestamp + _sum(durations, k));
            (, uint256 amountOutNext,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            assertEq(amountOutNext, PiecewiseLinearScaleArgsBuilder.scaleValue(makingAmount, scales[k]));

            // Mid point
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k)) / 2);
            (, uint256 amountOutMidLeft,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            vm.warp(timestamp + (_sum(durations, k - 1) + _sum(durations, k) + 1) / 2);
            (, uint256 amountOutMidRight,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            assertApproxEqAbs((amountOutMidLeft + amountOutMidRight) / 2, (amountOutPast + amountOutNext) / 2, (makingAmount >> 24) + 1);
        }
    }

    function test_PiecewiseLinearScale_GasBenchmark() public {
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
                swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
                uint256 temp = gas - gasleft();
                usage += temp;
                if (worst < temp) worst = temp;
            }

            console.log(usage / (length + 1), worst, length);
        }
    }

    function test_PiecewiseLinearScale_Basic() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint16[] memory durations = new uint16[](5);
        uint24[] memory scales = new uint24[](6);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 100;  scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 200;  scales[2] = uint24(2 ** 20 * 5 - 1);
            durations[2] = 100;  scales[3] = uint24(2 ** 22 - 1);
            durations[3] = 0;    scales[4] = uint24(2 ** 21 - 1);
            durations[4] = 100;  scales[5] = uint24(2 ** 20 * 3 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_201_007);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 24_874_999);
        }
        {
            vm.warp(1050);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 53_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 18_750_000);
        }
        {
            vm.warp(1100);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
        {
            vm.warp(1101);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_150_285);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_476_562);
        }
        {
            vm.warp(1270);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 117_431_196);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 8_515_625);
        }
        {
            vm.warp(1300);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 128_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 7_812_500);
        }
        {
            vm.warp(1301);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 128_256_518);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 7_796_875);
        }
        {
            vm.warp(1350);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 142_222_222);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 7_031_250);
        }
        {
            vm.warp(1400);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
        {
            vm.warp(1425);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 284_444_444);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_515_625);
        }
        {
            vm.warp(1450);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 256_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_906_250);
        }
        {
            vm.warp(1500);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
        {
            vm.warp(1501);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
        {
            vm.warp(100_000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_Single() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_Double() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 0;    scales[2] = uint24(2 ** 22 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_SingleWrapped() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](3);
        uint24[] memory scales = new uint24[](4);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 0;    scales[2] = uint24(2 ** 22 - 1);
            durations[2] = 2;    scales[3] = uint24(2 ** 21 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 53_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 18_750_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
        {
            vm.warp(1004);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 320_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_125_000);
        }
        {
            vm.warp(1005);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 320_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_125_000);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_DoubleWrapped() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](4);
        uint24[] memory scales = new uint24[](5);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 0;    scales[2] = uint24(2 ** 21 * 3 - 1);
            durations[2] = 0;    scales[3] = uint24(2 ** 22 - 1);
            durations[3] = 2;    scales[4] = uint24(2 ** 21 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 53_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 18_750_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
        {
            vm.warp(1004);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 320_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_125_000);
        }
        {
            vm.warp(1005);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 320_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 3_125_000);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_SingleFirst() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 0;    scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 2;    scales[2] = uint24(2 ** 22 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 106_666_666);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 9_375_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
    }

    function test_PiecewiseLinearScale_ZeroDuration_SingleLast() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint256 amountIn = 10_000_000;
        uint256 amountOut = 100_000_000;

        uint16[] memory durations = new uint16[](2);
        uint24[] memory scales = new uint24[](3);
        uint40 timestamp = 1000; scales[0] = uint24(2 ** 24 - 1);
            durations[0] = 2;    scales[1] = uint24(2 ** 23 - 1);
            durations[1] = 0;    scales[2] = uint24(2 ** 22 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamp, durations, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        {
            vm.warp(999);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1000);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
        }
        {
            vm.warp(1001);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 53_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 18_750_000);
        }
        {
            vm.warp(1002);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 80_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 12_500_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
        }
        {
            vm.warp(1003);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 160_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 6_250_000);
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
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
