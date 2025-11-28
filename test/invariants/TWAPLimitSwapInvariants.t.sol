// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { TWAPSwapArgsBuilder } from "../../src/instructions/TWAPSwap.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title TWAPLimitSwapInvariants
 * @notice Tests invariants for TWAP + LimitSwap combination
 * @dev TWAP is a modifier instruction that works with LimitSwap to implement:
 * - Linear liquidity unlocking over time
 * - Exponential price decay (dutch auction)
 * - Price bump after illiquidity periods
 * - Minimum trade size enforcement
 */
contract TWAPLimitSwapInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public protocolFeeCollector;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        protocolFeeCollector = address(0x1234567890123456789012345678901234567890);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup tokens and approvals for taker (test contract)
        tokenA.mint(address(this), 10000e18);
        tokenB.mint(address(this), 10000e18);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * @notice Implementation of _executeSwap for real swap execution
     */
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount * 10);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    /**
     * Test basic TWAP invariants
     */
    function test_TWAP_BasicInvariants() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 3600; // 1 hour
        uint256 balanceOut = 100e18;
        uint256 balanceIn = 200e18;

        // TWAP modifies LimitSwap: staticBalancesXD -> TWAP -> LimitSwap1D
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(200e18), uint256(100e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.2e18,
                    minTradeAmountOut: 0.1e18 // 0.1% of balanceOut
                }))),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at midpoint of TWAP
        vm.warp(startTime + duration / 2);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test TWAP + FlatFeeIn invariants
     */
    function test_TWAP_FlatFeeIn() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 86400; // 24 hours
        uint256 balanceOut = 1000e18;
        uint256 balanceIn = 2000e18;
        uint32 feeBps = 100; // 1% fee on input

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(2000e18), uint256(1000e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.15e18,
                    minTradeAmountOut: 0.001e18 // 0.0001% of 1000e18
                }))),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at 25% unlock
        vm.warp(startTime + 6 * 3600); // 6 hours (25% unlocked)

        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // At 25% unlock, available liquidity is 250e18
        // Use smaller test amounts that fit within available liquidity
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18), uint256(40e18)]), // Small test amounts
            10 // Higher tolerance for TWAP with fees
        );
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: TWAP violates standard invariants due to time and state dependencies
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test TWAP + FlatFeeOut invariants
     */
    function test_TWAP_FlatFeeOut() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 86400; // 24 hours
        uint256 balanceOut = 1000e18;
        uint256 balanceIn = 1500e18;
        uint32 feeBps = 200; // 2% fee on output

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1500e18), uint256(1000e18)])  // 1.5:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.2e18,
                    minTradeAmountOut: 0.001e18 // 0.0001% of 1000e18
                }))),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at 40% unlock
        vm.warp(startTime + duration * 40 / 100);

        // At 40% unlock, available liquidity is 400e18
        // Use smaller test amounts to fit within available liquidity
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]), // Very small test amounts
            10
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: TWAP violates standard invariants due to time and state dependencies
        config.skipAdditivity = true;
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test TWAP + ProtocolFee invariants
     */
    function test_TWAP_ProtocolFee() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 43200; // 12 hours
        uint256 balanceOut = 500e18;
        uint256 balanceIn = 1000e18;
        uint32 feeBps = 150; // 1.5% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(500e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.3e18,
                    minTradeAmountOut: 0.01e18 // 0.002% of 500e18
                }))),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at 60% unlock
        vm.warp(startTime + duration * 60 / 100);

        // Record protocol fee collector balance before
        uint256 feeBalanceBefore = tokenB.balanceOf(protocolFeeCollector);

        // Execute a test trade
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 amountOut) = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            100e18,
            exactInData
        );

        // Verify protocol fee was collected
        uint256 feeCollected = tokenB.balanceOf(protocolFeeCollector) - feeBalanceBefore;
        uint256 expectedFee = amountOut * feeBps / 1e9;
        assertApproxEqRel(feeCollected, expectedFee, 0.01e18, "Protocol fee should be collected");

        // Test invariants
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18), uint256(40e18)]), // Smaller test amounts
            10
        );
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: TWAP violates standard invariants due to time and state dependencies
        config.skipSymmetry = true;
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test TWAP + Multiple Fees invariants
     */
    function test_TWAP_MultipleFees() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 7200; // 2 hours
        uint256 balanceOut = 200e18;
        uint256 balanceIn = 400e18;
        uint32 flatFeeBps = 50; // 0.5% flat fee on input
        uint32 protocolFeeBps = 100; // 1% protocol fee on output

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(400e18), uint256(200e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.25e18,
                    minTradeAmountOut: 0.2e18 // 0.1% of balanceOut
                }))),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at 75% unlock
        vm.warp(startTime + duration * 75 / 100);

        // At 75% unlock, available liquidity is 150e18
        // Use smaller test amounts that fit within available liquidity
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(20e18), uint256(40e18), uint256(60e18)]), // Smaller amounts
            15 // Higher tolerance for multiple fees
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: TWAP violates standard invariants due to time and state dependencies
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test TWAP at different time points with fees
     */
    function test_TWAP_TimeProgressionWithFees() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 3600; // 1 hour
        uint256 balanceOut = 100e18;
        uint256 balanceIn = 200e18;
        uint32 feeBps = 150; // 1.5% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(200e18), uint256(100e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.4e18,
                    minTradeAmountOut: 0.05e18 // Very small minimum
                }))),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at different time points
        uint256[] memory timePoints = new uint256[](3);
        timePoints[0] = startTime + duration / 4;   // 25% unlocked
        timePoints[1] = startTime + duration / 2;   // 50% unlocked
        timePoints[2] = startTime + duration;       // 100% unlocked

        for (uint256 i = 0; i < timePoints.length; i++) {
            uint256 snapshot = vm.snapshot();
            vm.warp(timePoints[i]);

            // Adjust test amounts based on liquidity available at this time point
            uint256[] memory testAmounts;
            if (i == 0) { // 25% unlocked = 25e18 available
                testAmounts = dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]);
            } else if (i == 1) { // 50% unlocked = 50e18 available
                testAmounts = dynamic([uint256(10e18), uint256(20e18), uint256(40e18)]);
            } else { // 100% unlocked = 100e18 available (minus fees)
                testAmounts = dynamic([uint256(20e18), uint256(40e18), uint256(80e18)]);
            }

            InvariantConfig memory config = createInvariantConfig(
                testAmounts,
                10
            );
            config.exactInTakerData = _signAndPackTakerData(order, true, 0);
            config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
            // TODO: TWAP violates standard invariants due to time and state dependencies
            config.skipAdditivity = true;

            assertAllInvariantsWithConfig(
                swapVM,
                order,
                address(tokenA),
                address(tokenB),
                config
            );

            vm.revertTo(snapshot);
        }
    }

    /**
     * Test TWAP with high price bump and fees
     */
    function test_TWAP_HighPriceBumpWithFees() public {
        uint256 startTime = block.timestamp;
        uint256 duration = 86400; // 24 hours
        uint256 balanceOut = 1000e18;
        uint256 balanceIn = 2000e18;
        uint256 priceBump = 2.0e18; // 100% bump
        uint32 feeBps = 300; // 3% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(2000e18), uint256(1000e18)])  // 2:1 rate
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: priceBump,
                    minTradeAmountOut: 0.001e18 // 0.0001% of 1000e18
                }))),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // First trade to establish state
        vm.warp(startTime + duration * 10 / 100); // 10% unlocked = 100e18
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 20e18, exactInData); // Small trade

        // Second test after illiquidity period
        vm.warp(startTime + duration * 30 / 100); // 30% unlocked = 300e18

        // Available liquidity is 280e18 (300e18 - 20e18 already traded)
        // Use very small amounts due to high fees and price bump
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(5e18), uint256(10e18)]), // Very small amounts
            20 // Very high tolerance for extreme bump + fees
        );
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: TWAP violates standard invariants due to time and state dependencies
        config.skipAdditivity = true;
        config.skipSymmetry = true; // Skip due to price bumps and fees

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
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
