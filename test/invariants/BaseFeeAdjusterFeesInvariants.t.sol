// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { DutchAuctionArgsBuilder } from "../../src/instructions/DutchAuction.sol";
import { BaseFeeAdjusterArgsBuilder } from "../../src/instructions/BaseFeeAdjuster.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title BaseFeeAdjusterFeesInvariants
 * @notice Tests invariants for BaseFeeAdjuster combined with LimitSwap and various fee types
 * @dev Tests gas-based price adjustments with different fee mechanisms
 */
contract BaseFeeAdjusterFeesInvariants is Test, OpcodesDebug, CoreInvariants {
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
        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 2e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
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

        // Verify the swap consumed the expected input amount


        return (actualIn, actualOut);
    }

    /**
     * Test BaseFeeAdjuster with flat fee on input
     */
    function test_BaseFeeAdjuster_FlatFeeIn() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16;
        uint32 feeBps = 100; // 1% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 150 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with flat fee on output
     */
    function test_BaseFeeAdjuster_FlatFeeOut() public {
        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 2500e18;
        uint24 gasAmount = 180_000;
        uint64 maxPriceDecay = 98e16;
        uint32 feeBps = 200; // 2% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 100 gwei, true, true, false);
    }


    /**
     * Test BaseFeeAdjuster with protocol fee
     */
    function test_BaseFeeAdjuster_ProtocolFee() public {
        uint64 baseGasPrice = 22 gwei;
        uint96 ethToTokenPrice = 3200e18;
        uint24 gasAmount = 155_000;
        uint64 maxPriceDecay = 98e16;
        uint32 feeBps = 150; // 1.5% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 180 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with multiple fees
     */
    function test_BaseFeeAdjuster_MultipleFees() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16;
        uint32 flatFeeBps = 50; // 0.5% flat fee
        uint32 protocolFeeBps = 100; // 1% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            // Multiple fees
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 150 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with high fees
     */
    function test_BaseFeeAdjuster_HighFees() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 95e16; // More aggressive adjustment
        uint32 feeBps = 1000; // 10% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 200 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on input and flat fee on input
     */
    function test_BaseFeeAdjuster_DutchAuctionIn_FlatFeeIn() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16;
        uint32 feeBps = 100; // 1% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // Test at mid-auction with high gas
        vm.warp(startTime + 150);
        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 200 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on output and flat fee on output
     */
    function test_BaseFeeAdjuster_DutchAuctionOut_FlatFeeOut() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16;
        uint32 feeBps = 150; // 1.5% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceOut1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // Test at mid-auction with high gas
        vm.warp(startTime + 150);
        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 200 gwei, true, true, false);
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on input and protocol fee
     */
    function test_BaseFeeAdjuster_DutchAuctionIn_ProtocolFee() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;  // Less aggressive decay

        uint64 baseGasPrice = 30 gwei;
        uint96 ethToTokenPrice = 2800e18;
        uint24 gasAmount = 100_000;  // Reduced gas amount
        uint64 maxPriceDecay = 99e16;  // Less aggressive max price adjustment
        uint32 feeBps = 200; // 2% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // Test at mid-auction with moderate gas
        vm.warp(startTime + 150);
        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 100 gwei, true, true, false);  // Reduced gas price
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on output and multiple fees
     */
    function test_BaseFeeAdjuster_DutchAuctionOut_MultipleFees() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3200e18;
        uint24 gasAmount = 160_000;
        uint64 maxPriceDecay = 97e16;
        uint32 flatFeeBps = 75; // 0.75% flat fee
        uint32 protocolFeeBps = 100; // 1% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceOut1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeCollector)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_baseFeeAdjuster1D,
                BaseFeeAdjusterArgsBuilder.build(
                    baseGasPrice,
                    ethToTokenPrice,
                    gasAmount,
                    maxPriceDecay
                ))
        );

        // Test at mid-auction with high gas
        vm.warp(startTime + 150);
        // TODO: BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments
        _testInvariantsWithConfig(bytecode, 200 gwei, true, true, false);
    }

    /**
     * Helper to test invariants for a given bytecode and gas price
     *
     * @notice BaseFeeAdjuster breaks symmetry and additivity invariants due to its asymmetric
     * application of gas cost adjustments:
     * - In exactIn mode: it increases amountOut based on (extraCostInToken1 / amountOut)
     * - In exactOut mode: it decreases amountIn based on (extraCostInToken1 / amountIn)
     *
     * This asymmetry means that:
     * 1. exactIn(X) -> Y, then exactOut(Y) -> X' where X' ≠ X (breaks symmetry)
     * 2. The sum of partial swaps differs from a full swap (breaks additivity)
     *
     * The percentage adjustments are calculated against different bases (amountOut vs amountIn),
     * causing the invariant violations. This issue is compounded when combined with fees.
     */
    function _testInvariantsWithConfig(
        bytes memory bytecode,
        uint256 gasPrice,
        bool skipAdditivity,
        bool skipSymmetry,
        bool skipMonotonicity
    ) private {
        ISwapVM.Order memory order = _createOrder(bytecode);

        // Set gas price
        vm.fee(gasPrice);

        // Use smaller test amounts to avoid overflow with gas adjustments and fees
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;
        testAmounts[1] = 5000e18;
        testAmounts[2] = 10000e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 100); // 100 wei tolerance
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        // Skip invariants based on parameters
        // TODO: Research if additivity can be preserved for gas-adjusted orders with fees
        config.skipAdditivity = skipAdditivity;

        // TODO: Research if symmetry can be restored despite asymmetric gas adjustments and fees
        config.skipSymmetry = skipSymmetry;

        // TODO: Research monotonicity behavior with progressive fees and gas adjustment
        config.skipMonotonicity = skipMonotonicity;

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
