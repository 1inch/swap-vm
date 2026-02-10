// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { DutchAuctionArgsBuilder } from "../src/instructions/DutchAuction.sol";
import { BaseFeeAdjusterArgsBuilder } from "../src/instructions/BaseFeeAdjuster.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title BaseFeeAdjusterTest
 * @notice Tests for BaseFeeAdjuster instruction functionality
 * @dev Tests gas-based price adjustments for limit orders
 */
contract BaseFeeAdjusterTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test BaseFeeAdjuster with LimitSwap at different gas prices
     */
    function test_BaseFeeAdjusterLimitSwapGasVariations() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18; // 1 ETH = 3000 tokens
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16; // 0.99 = 1% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),  // Swap B to A (token1 to token0)
                    dynamic([uint256(300000e18), uint256(100e18)]) // 3000:1 rate
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at different gas prices
        uint256[] memory gasPrices = new uint256[](4);
        gasPrices[0] = 20 gwei;   // Base gas price - no adjustment
        gasPrices[1] = 50 gwei;   // Moderate gas - some adjustment
        gasPrices[2] = 100 gwei;  // High gas - significant adjustment
        gasPrices[3] = 200 gwei;  // Very high gas - max adjustment

        uint256[] memory expectedOutputs = new uint256[](4);

        for (uint256 i = 0; i < gasPrices.length; i++) {
            // Set base fee (gas price)
            vm.fee(gasPrices[i]);

            bytes memory exactInData = _signAndPackTakerData(order, true, 0);

            // Quote with current gas conditions - swap B to A
            (, uint256 quotedOut,) = swapVM.asView().quote(
                order,
                address(tokenB),
                address(tokenA),
                3000e18, // 3000 tokenB
                exactInData
            );

            expectedOutputs[i] = quotedOut;
        }

        // Verify outputs increase with gas price (or stay same if capped)
        for (uint256 i = 1; i < expectedOutputs.length; i++) {
            assertGe(expectedOutputs[i], expectedOutputs[i-1], "Higher gas should improve or maintain price");
        }
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction combination
     */
    function test_BaseFeeAdjusterWithDutchAuction() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300; // 5 minutes
        uint64 decayFactor = 0.999e18; // 0.999 = 0.1% decay per second

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3500e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16; // 0.99 = 1% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]), // Swap B to A
                    dynamic([uint256(3500000e18), uint256(1000e18)]) // 3500:1 rate
                )),
            // DutchAuction adjusts balances, then LimitSwap computes amounts
            program.build(_dutchAuctionBalanceOut1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            // BaseFeeAdjuster must be applied after the swap
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at different times and gas prices
        uint256[] memory timeOffsets = new uint256[](3);
        timeOffsets[0] = 0;    // Start
        timeOffsets[1] = 150;  // Mid auction
        timeOffsets[2] = 299;  // Near end

        uint256[] memory gasPrices = new uint256[](2);
        gasPrices[0] = 30 gwei;
        gasPrices[1] = 100 gwei;

        for (uint256 t = 0; t < timeOffsets.length; t++) {
            for (uint256 g = 0; g < gasPrices.length; g++) {
                uint256 snapshot = vm.snapshot();

                vm.warp(startTime + timeOffsets[t]);
                vm.fee(gasPrices[g]);

                bytes memory exactInData = _signAndPackTakerData(order, true, 0);

                (, uint256 quotedOut,) = swapVM.asView().quote(
                    order,
                    address(tokenB),
                    address(tokenA),
                    3500e18, // 3500 tokenB
                    exactInData
                );

                // Ensure we have valid output
                assertGt(quotedOut, 0, "Should get positive output");

                vm.revertTo(snapshot);
            }
        }
    }

    /**
     * Test max price decay limits
     */
    function test_BaseFeeAdjusterMaxDecayLimits() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 95e16; // 0.95 = 5% max adjustment - generous limit

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]), // Swap B to A
                    dynamic([uint256(300000e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at extremely high gas price
        vm.fee(1000 gwei); // Very high gas

        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        (, uint256 quotedOut,) = swapVM.asView().quote(
            order,
            address(tokenB),
            address(tokenA),
            3000e18, // 3000 tokenB input
            exactInData
        );

        // Should be capped by maxPriceDecay
        // Base output is 1, max increase with 5% cap = 1 * 1.05 = 1.05
        assertLe(quotedOut, 1.05e18, "Should be capped by max decay");
        assertGe(quotedOut, 1e18, "Should improve from base price");
    }

    /**
     * Test that adjustment only occurs above base gas price
     */
    function test_BaseFeeAdjusterNoAdjustmentBelowBase() public {
        uint64 baseGasPrice = 50 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16; // 0.99 = 1% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]), // Swap B to A
                    dynamic([uint256(300000e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Test at gas price below base
        vm.fee(30 gwei); // Below base of 50 gwei

        (, uint256 outputLowGas,) = swapVM.asView().quote(
            order,
            address(tokenB),
            address(tokenA),
            3000e18,
            exactInData
        );

        // Test at base gas price
        vm.fee(50 gwei);

        (, uint256 outputBaseGas,) = swapVM.asView().quote(
            order,
            address(tokenB),
            address(tokenA),
            3000e18,
            exactInData
        );

        // Should be same - no adjustment below base
        assertEq(outputLowGas, outputBaseGas, "No adjustment below base gas");
        assertEq(outputLowGas, 1e18, "Should be base price");
    }

    /**
     * @notice Test exact compensation calculation for exactIn mode
     * @dev This test would have caught the original bug where amountOut was used instead of amountIn
     */
    function test_BaseFeeAdjusterExactCompensation() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToToken1Price = 3000e18; // 1 ETH = 3000 USDC
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 90e16; // 10% max (high to not interfere with test)

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),
                    dynamic([uint256(300000e18), uint256(100e18)]) // 3000:1 rate
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Base case
        vm.fee(20 gwei);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 baseOutput,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 3000e18, exactInData);

        // High gas
        vm.fee(100 gwei);
        (, uint256 adjustedOutput,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 3000e18, exactInData);

        // Expected: 0.012 ETH gas cost = 1.2% of 1 ETH = 1.2% compensation
        uint256 expectedCompensation = 0.012e18;
        uint256 actualCompensation = adjustedOutput - baseOutput;

        assertEq(baseOutput, 1e18, "Base should be 1.0");
        assertApproxEqAbs(actualCompensation, expectedCompensation, 0.001e18, "Should compensate ~1.2%");
    }

    /**
     * @notice Test compensation scales inversely with swap size
     */
    function test_BaseFeeAdjusterCompensationScaling() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToToken1Price = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 90e16; // 10% max

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),
                    dynamic([uint256(300000e18), uint256(100e18)]) // 3000:1 rate
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(20 gwei);
        (, uint256 smallBase,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 300e18, exactInData);
        (, uint256 largeBase,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 3000e18, exactInData);

        vm.fee(100 gwei);
        (, uint256 smallAdjusted,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 300e18, exactInData);
        (, uint256 largeAdjusted,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 3000e18, exactInData);

        uint256 smallPct = ((smallAdjusted - smallBase) * 100e18) / smallBase;
        uint256 largePct = ((largeAdjusted - largeBase) * 100e18) / largeBase;

        // Small swap (0.1 ETH): 12% theoretical → capped at 10%
        // Large swap (1 ETH): 1.2% theoretical
        assertEq(smallPct / 1e18, 10, "Small swap hits 10% cap");
        assertApproxEqAbs(largePct, 1.2e18, 0.01e18, "Large swap ~1.2%");
    }

    /**
     * @notice Test exactOut mode provides correct discount
     */
    function test_BaseFeeAdjusterExactOutDiscount() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToToken1Price = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 90e16; // 10% max

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenB), address(tokenA)]),
                    dynamic([uint256(300000e18), uint256(100e18)]) // 3000:1 rate
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(baseGasPrice, ethToToken1Price, gasAmount, maxPriceDecay))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactOutData = _signAndPackTakerData(order, false, 0);

        vm.fee(20 gwei);
        (uint256 baseInput,,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 1e18, exactOutData);

        vm.fee(100 gwei);
        (uint256 adjustedInput,,) = swapVM.asView().quote(order, address(tokenB), address(tokenA), 1e18, exactOutData);

        // Expected: 36 USDC discount on 3000 USDC = 1.2%
        uint256 expectedDiscount = 36e18;
        uint256 actualDiscount = baseInput - adjustedInput;

        assertEq(baseInput, 3000e18, "Base should be 3000");
        assertLt(adjustedInput, baseInput, "Should pay less at high gas");
        assertApproxEqAbs(actualDiscount, expectedDiscount, 1e18, "Discount ~36 USDC");
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
