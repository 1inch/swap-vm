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
        uint40[] memory timestamps,
        uint24[] memory scales,
        bool scaleIn
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([balanceIn, balanceOut]))),
            scaleIn
                ? p.build(_piecewiseLinearScaleBalanceIn1D, PiecewiseLinearScaleArgsBuilder.build(timestamps, scales))
                : p.build(_piecewiseLinearScaleBalanceOut1D, PiecewiseLinearScaleArgsBuilder.build(timestamps, scales)),
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
        uint24[7] memory scaleSeed,
        uint32[7] memory timestampGapSeed
    ) public {
        makingAmount = bound(makingAmount, 2, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 2, MAX_AMOUNT);

        uint256 pointsCount = bound(pointsCountSeed, 2, 7);
        uint40[] memory timestamps = new uint40[](pointsCount);
        uint24[] memory scales = new uint24[](pointsCount);

        uint256 last = pointsCount - 1;

        // Strictly increasing timestamps and descending, scales in [0, 2 ** 24 - 1]
        timestamps[0] = uint40(bound(timestampGapSeed[0], 1, 1e9));
        scales[0] = type(uint24).max; // Initial scale = 1.0
        for (uint256 i = 1; i < pointsCount; i++) {
            timestamps[i] = timestamps[i - 1] + uint40(bound(timestampGapSeed[i], 1, 1e9));
            scales[i] = uint24(bound(scaleSeed[i], 0, uint256(scales[i - 1])));
        }

        // It is important that `balanceIn` is not `takingAmount` and should be calculated
        uint256 balanceIn = PiecewiseLinearScaleArgsBuilder.unscaleValue(takingAmount, scales[last]);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, makingAmount, timestamps, scales, true));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;

        // At the initial point the whole `makingAmount` sells for exactly `balanceIn`, and one wei less in buys strictly less
        vm.warp(timestamps[0]);
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
        vm.warp(timestamps[last]);
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
            vm.warp(timestamps[k - 1]);
            (uint256 amountInPast,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);

            // Predictable at exact point
            vm.warp(timestamps[k]);
            (uint256 amountInNext,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
            assertEq(amountInNext, PiecewiseLinearScaleArgsBuilder.scaleValue(balanceIn, scales[k]));

            // Mid point
            vm.warp((timestamps[k - 1] + timestamps[k]) / 2);
            (uint256 amountInMidLeft,,) = swapVM.quote(order, address(tokenA), address(tokenB), makingAmount, takerDataExactOut);
            vm.warp((timestamps[k - 1] + timestamps[k] + 1) / 2);
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
        uint24[7] memory scaleSeed,
        uint32[7] memory timestampGapSeed
    ) public {
        makingAmount = bound(makingAmount, 2, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 2, MAX_AMOUNT);

        uint256 pointsCount = bound(pointsCountSeed, 2, 7);
        uint40[] memory timestamps = new uint40[](pointsCount);
        uint24[] memory scales = new uint24[](pointsCount);

        uint256 last = pointsCount - 1;

        // Strictly increasing timestamps and ascending, scales in [0, 2**24 - 1]
        timestamps[0] = uint40(bound(timestampGapSeed[0], 1, 1e9));
        // Initial scale set so that minimal balanceOut >= 2
        scales[0] = uint24(bound(scaleSeed[0], (2 * 2 ** 24 + makingAmount - 1) / makingAmount - 1, type(uint24).max));
        for (uint256 i = 1; i < pointsCount; i++) {
            timestamps[i] = timestamps[i - 1] + uint40(bound(timestampGapSeed[i], 1, 1e9));
            scales[i] = uint24(bound(scaleSeed[i], uint256(scales[i - 1]), type(uint24).max));
        }
        scales[last] = type(uint24).max; // Last scale = 1.0

        // Here `balanceOut = makingAmount` with last scale 1.0
        ISwapVM.Order memory order = _buildOrder(_buildProgram(takingAmount, makingAmount, timestamps, scales, false));
        bytes memory takerDataExactIn = _buildTakerData(true);
        bytes memory takerDataExactOut = _buildTakerData(false);

        uint256 amountOut;
        uint256 amountIn;

        // The least `balanceOut` with the worst scale
        uint256 balanceOutInitial = PiecewiseLinearScaleArgsBuilder.scaleValue(makingAmount, scales[0]);

        // At the initial point the whole `takingAmount` sells for exactly `balanceOutInitial`, and one wei less in sells strictly less
        vm.warp(timestamps[0]);
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
        vm.warp(timestamps[last]);
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
            vm.warp(timestamps[k - 1]);
            (, uint256 amountOutPast,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);

            // Predictable at exact point
            vm.warp(timestamps[k]);
            (, uint256 amountOutNext,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            assertEq(amountOutNext, PiecewiseLinearScaleArgsBuilder.scaleValue(makingAmount, scales[k]));

            // Mid point
            vm.warp((timestamps[k - 1] + timestamps[k]) / 2);
            (, uint256 amountOutMidLeft,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            vm.warp((timestamps[k - 1] + timestamps[k] + 1) / 2);
            (, uint256 amountOutMidRight,) = swapVM.quote(order, address(tokenA), address(tokenB), takingAmount, takerDataExactIn);
            assertApproxEqAbs((amountOutMidLeft + amountOutMidRight) / 2, (amountOutPast + amountOutNext) / 2, (makingAmount >> 24) + 1);
        }
    }

    function test_PiecewiseLinearScale_GasBenchmark() public {
        // Warmup account
        address(swapVM).staticcall("");

        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        for (uint256 length = 2; length < 32; ++length) {
            uint40[] memory timestamps = new uint40[](length);
            uint24[] memory scales = new uint24[](length);

            timestamps[0] = 50;
            scales[0] = type(uint24).max;
            for (uint256 i = 1; i < length; ++i) {
                timestamps[i] = timestamps[i - 1] + 100;
                scales[i] = scales[0];
            }

            ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamps, scales, true));
            bytes memory takerDataExactIn = _buildTakerData(true);

            uint256 amountIn = 10_000_000;

            uint256 usage;
            uint256 worst;

            for (uint256 i = 1; i < length; ++i) {
                vm.warp(i * 100);
                uint256 gas = gasleft();
                swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
                uint256 temp = gas - gasleft();
                usage += temp;
                if (worst < temp) worst = temp;
            }

            console.log(usage / (length - 1), worst, length);
        }
    }

    function test_PiecewiseLinearScale_ExactIn_5points_ScaleIn_Basic() public {
        uint256 balanceIn = 1000e18;
        uint256 balanceOut = 4000e18;

        uint40[] memory timestamps = new uint40[](5);
        uint24[] memory scales = new uint24[](5);
        timestamps[0] = 1000; scales[0] = uint24(2 ** 24 - 1);
        timestamps[1] = 1100; scales[1] = uint24(2 ** 23 - 1);
        timestamps[2] = 1300; scales[2] = uint24(2 ** 20 * 5 - 1);
        timestamps[3] = 1400; scales[3] = uint24(2 ** 22 - 1);
        timestamps[4] = 1500; scales[4] = uint24(2 ** 20 * 3 - 1);

        ISwapVM.Order memory order = _buildOrder(_buildProgram(balanceIn, balanceOut, timestamps, scales, true));
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
            vm.warp(1500);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 213_333_333);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 4_687_500);
        }
        {
            vm.warp(1501);
            (, uint256 amountOutCalc,) = swapVM.quote(order, address(tokenA), address(tokenB), amountIn, takerDataExactIn);
            assertEq(amountOutCalc, 40_000_000);
            (uint256 amountInCalc,,) = swapVM.quote(order, address(tokenA), address(tokenB), amountOut, takerDataExactOut);
            assertEq(amountInCalc, 25_000_000);
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
