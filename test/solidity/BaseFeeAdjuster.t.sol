// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { DutchAuctionBalanceOut } from "../../contracts/instructions/DutchAuction.sol";
import { PiecewiseLinearSurchargeBalanceIn, PiecewiseLinearSurchargeBalanceOut } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../../contracts/instructions/BaseFeeAdjuster.sol";

/**
 * @title BaseFeeAdjusterTest
 * @notice Tests gas-cost compensation against accumulated balance surcharges
 */
contract BaseFeeAdjusterTest is Test, OpcodesDebug {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with LimitSwap at different gas prices.
     */
    function test_BaseFeeAdjusterLimitSwapGasVariations() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 1e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceInProgram(
                balanceIn,
                balanceOut,
                surchargeScale,
                baseGasPrice,
                ethToTokenPrice,
                gasAmount
            )
        );
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256[] memory gasPrices = new uint256[](4);
        gasPrices[0] = 20 gwei;
        gasPrices[1] = 50 gwei;
        gasPrices[2] = 100 gwei;
        gasPrices[3] = 200 gwei;

        uint256 amountIn = 1000e18;
        uint256 surcharge = PiecewiseLinearSurchargeBalanceIn.scaleValue(balanceIn, surchargeScale);
        uint256 previousOutput;

        for (uint256 i = 0; i < gasPrices.length; i++) {
            vm.fee(gasPrices[i]);
            (, uint256 quotedOut,) = swapVM.asView().quote(order, amountIn, exactInData);

            uint256 discount;
            if (gasPrices[i] > baseGasPrice) {
                discount = (gasPrices[i] - baseGasPrice) * gasAmount * ethToTokenPrice / 1e18;
                if (discount > surcharge) discount = surcharge;
            }
            uint256 expectedOut = amountIn * balanceOut / (balanceIn + surcharge - discount);

            assertEq(quotedOut, expectedOut, "Unexpected gas adjustment");
            assertGe(quotedOut, previousOutput, "Higher gas should not worsen the taker price");
            previousOutput = quotedOut;
        }
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with a Dutch auction at different times.
     */
    function test_BaseFeeAdjusterWithDutchAuction() public {
        uint40 startTime = uint40(block.timestamp);
        uint64 decayFactor = 0.999e18;
        uint24 surchargeBps = 0.5e7;
        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3500e18;
        uint24 gasAmount = 150_000;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1000e18, 3500e18),
            DutchAuctionBalanceOut.build(startTime, decayFactor, surchargeBps),
            BaseFeeAdjusterBalanceOut.build(baseGasPrice, ethToTokenPrice, gasAmount),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256[] memory timeOffsets = new uint256[](3);
        timeOffsets[0] = 0;
        timeOffsets[1] = 150;
        timeOffsets[2] = 299;

        for (uint256 i = 0; i < timeOffsets.length; i++) {
            vm.warp(startTime + timeOffsets[i]);

            vm.fee(30 gwei);
            (, uint256 lowGasOutput,) = swapVM.asView().quote(order, 100e18, exactInData);

            vm.fee(100 gwei);
            (, uint256 highGasOutput,) = swapVM.asView().quote(order, 100e18, exactInData);

            assertGt(lowGasOutput, 0, "Dutch auction should produce output");
            assertGe(highGasOutput, lowGasOutput, "Higher gas should consume more surcharge");
        }
    }

    /**
     * Test that compensation cannot exceed the accumulated surcharge.
     */
    function test_BaseFeeAdjusterSurchargeCap() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 1e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 20);

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceInProgram(
                balanceIn,
                balanceOut,
                surchargeScale,
                20 gwei,
                3000e18,
                150_000
            )
        );
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(1000 gwei);
        (, uint256 quotedOut,) = swapVM.asView().quote(order, balanceIn, exactInData);

        assertEq(quotedOut, balanceOut, "Compensation should stop at the unsurcharged balance");
    }

    /**
     * Test that adjustment only occurs above the configured base gas price.
     */
    function test_BaseFeeAdjusterNoAdjustmentBelowBase() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 1e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceInProgram(
                balanceIn,
                balanceOut,
                surchargeScale,
                50 gwei,
                3000e18,
                150_000
            )
        );
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(30 gwei);
        (, uint256 outputLowGas,) = swapVM.asView().quote(order, balanceIn, exactInData);

        vm.fee(50 gwei);
        (, uint256 outputBaseGas,) = swapVM.asView().quote(order, balanceIn, exactInData);

        uint256 surcharge = PiecewiseLinearSurchargeBalanceIn.scaleValue(balanceIn, surchargeScale);
        uint256 expectedOutput = balanceIn * balanceOut / (balanceIn + surcharge);

        assertEq(outputLowGas, outputBaseGas, "No adjustment expected at or below base gas");
        assertEq(outputLowGas, expectedOutput, "Surcharge should remain untouched");
    }

    /**
     * Test exact token-out compensation through BaseFeeAdjusterBalanceOut.
     */
    function test_BaseFeeAdjusterExactCompensation() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 3e18;

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceOutProgram(
                balanceIn,
                balanceOut,
                uint24(1 << 23),
                20 gwei,
                1e18,
                150_000
            )
        );
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(20 gwei);
        (, uint256 baseOutput,) = swapVM.asView().quote(order, balanceIn, exactInData);

        vm.fee(100 gwei);
        (, uint256 adjustedOutput,) = swapVM.asView().quote(order, balanceIn, exactInData);

        assertEq(baseOutput, 2e18, "Unexpected surcharged output balance");
        assertEq(adjustedOutput - baseOutput, 0.012e18, "Incorrect gas compensation");
    }

    /**
     * Test that balance adjustment applies one rate to every non-partial swap size.
     */
    function test_BaseFeeAdjusterCompensationScaling() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 1e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceInProgram(
                balanceIn,
                balanceOut,
                surchargeScale,
                20 gwei,
                3000e18,
                150_000
            )
        );
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(100 gwei);
        (, uint256 smallOutput,) = swapVM.asView().quote(order, 100e18, exactInData);
        (, uint256 largeOutput,) = swapVM.asView().quote(order, 1000e18, exactInData);

        assertApproxEqAbs(largeOutput, smallOutput * 10, 9, "Compensation should preserve a linear rate");
    }

    /**
     * Test exact-out mode discounts the input-token virtual balance.
     */
    function test_BaseFeeAdjusterExactOutDiscount() public {
        uint256 balanceIn = 3000e18;
        uint256 balanceOut = 1e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);

        ISwapVM.Order memory order = _createOrder(
            _buildBalanceInProgram(
                balanceIn,
                balanceOut,
                surchargeScale,
                20 gwei,
                3000e18,
                150_000
            )
        );
        bytes memory exactOutData = _signAndPackTakerData(order, false, 0);

        vm.fee(20 gwei);
        (uint256 baseInput,,) = swapVM.asView().quote(order, balanceOut, exactOutData);

        vm.fee(100 gwei);
        (uint256 adjustedInput,,) = swapVM.asView().quote(order, balanceOut, exactOutData);

        uint256 surcharge = PiecewiseLinearSurchargeBalanceIn.scaleValue(balanceIn, surchargeScale);
        assertEq(baseInput, balanceIn + surcharge, "Unexpected surcharged input balance");
        assertEq(baseInput - adjustedInput, 36e18, "Incorrect input-token discount");
    }

    function _buildBalanceInProgram(
        uint256 balanceIn,
        uint256 balanceOut,
        uint24 surchargeScale,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethPrice, gasAmount),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    function _buildBalanceOutProgram(
        uint256 balanceIn,
        uint256 balanceOut,
        uint24 surchargeScale,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurchargeBalanceOut.build(uint40(block.timestamp), durations, scales),
            BaseFeeAdjusterBalanceOut.build(baseGasPrice, ethPrice, gasAmount),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
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

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            usePermit2: false,
            threshold: thresholdData,
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
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }
}
