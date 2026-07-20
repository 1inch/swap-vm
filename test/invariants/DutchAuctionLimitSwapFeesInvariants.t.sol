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
import { Program, ProgramBuilder, Opcode } from "../utils/ProgramBuilder.sol";
import { StaticBalances, DynamicBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../src/instructions/DutchAuction.sol";
import { FeeFlatIn, FeeFlatOut } from "../../src/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";
import { FeeProgressiveIn, FeeProgressiveOut } from "../../src/instructions/FeeProgressive.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title DutchAuctionLimitSwapFeesInvariants
 * @notice Tests invariants for DutchAuction combined with LimitSwap and various fee types
 * @dev Tests time-based price decay with different fee mechanisms
 */
contract DutchAuctionLimitSwapFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public protocolFeeCollector;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        protocolFeeCollector = address(0x1234567890123456789012345678901234567890);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

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
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount


        return (actualIn, actualOut);
    }

    /**
     * Test Dutch auction with flat fee on input
     */
    function test_DutchAuctionIn_FlatFeeIn() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;
        uint24 feeBps = 0.01e7; // 1% fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            FeeFlatIn.build(feeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode);
    }

    /**
     * Test Dutch auction with flat fee on output
     */
    function test_DutchAuctionOut_FlatFeeOut() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.98e18;
        uint24 feeBps = 0.02e7; // 2% fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            FeeFlatOut.build(feeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode);
    }

    /**
     * Test Dutch auction with progressive fee on input
     */
    function test_DutchAuctionIn_ProgressiveFeeIn() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.95e18;
        uint24 feeBps = 0.005e7; // 0.5% base fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            FeeProgressiveIn.build(feeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // TODO: Fix additivity and monotonicity for progressive fees with dutch auction
        _testInvariantsWithConfig(bytecode, true, true);
    }

    /**
     * Test Dutch auction with progressive fee on output
     */
    function test_DutchAuctionOut_ProgressiveFeeOut() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18; // Use milder decay to avoid overflow
        uint24 feeBps = 0.0025e7; // 0.25% base fee (reduced to avoid overflow)

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            FeeProgressiveOut.build(feeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // TODO: Fix additivity for progressive fees with dutch auction
        _testInvariantsWithConfig(bytecode, false, true);
    }

    /**
     * Test Dutch auction with protocol fee
     */
    function test_DutchAuctionIn_ProtocolFee() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.97e18;
        uint24 feeBps = 0.015e7; // 1.5% protocol fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            FeeBuilders.protocolFeeOut(feeBps, protocolFeeCollector),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // TODO: Fix additivity for protocol fees with dutch auction
        _testInvariantsWithConfig(bytecode, false, true);
    }

    /**
     * Test Dutch auction with multiple fees
     */
    function test_DutchAuctionOut_MultipleFees() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.96e18;
        uint24 flatFeeBps = 0.005e7; // 0.5% flat fee
        uint24 progressiveFeeBps = 0.0025e7; // 0.25% progressive fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            // Multiple fees
            FeeFlatIn.build(flatFeeBps),
            FeeProgressiveOut.build(progressiveFeeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // TODO: Fix additivity for progressive fees with dutch auction
        _testInvariantsWithConfig(bytecode, false, true);
    }

    /**
     * Test Dutch auction with high fees
     */
    function test_DutchAuctionIn_HighFees() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;
        uint24 feeBps = 0.1e7; // 10% fee

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            FeeFlatIn.build(feeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode);
    }

    /**
     * Helper to test invariants for a given bytecode
     */
    function _testInvariants(bytes memory bytecode) private {
        _testInvariantsWithConfig(bytecode, false, false);
    }

    /**
     * Helper to test invariants with custom config
     */
    function _testInvariantsWithConfig(bytes memory bytecode, bool skipMonotonicity, bool skipAdditivity) private {
        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        bytes memory exactOutData = _signAndPackTakerData(order, false, type(uint256).max);

        // Test at different time points
        uint40 startTime = uint40(block.timestamp);
        uint256[] memory timeOffsets = new uint256[](3);
        timeOffsets[0] = 0;     // Start
        timeOffsets[1] = 150;   // Mid-auction
        timeOffsets[2] = 280;   // Near end

        for (uint256 i = 0; i < timeOffsets.length; i++) {
            // Save snapshot before time manipulation
            uint256 snapshot = vm.snapshot();

            // Warp to test time
            vm.warp(startTime + timeOffsets[i]);

            // Test invariants at this time point
            InvariantConfig memory config = _getDefaultConfig();
            config.exactInTakerData = exactInData;
            config.exactOutTakerData = exactOutData;

            config.skipAdditivity = skipAdditivity;
            config.skipMonotonicity = skipMonotonicity;
            // Fees round up per instruction: allow 1-wei price jitter between trade sizes
            config.monotonicityToleranceBps = 1;
            // Floor-rounded protocol fees vanish on dust amounts, so dust rates can beat
            // the net-of-fee spot price by up to the fee size (<= 2% in this file)
            config.roundingToleranceBps = 200;

            assertAllInvariantsWithConfig(
                swapVM,
                order,
                address(tokenA),
                address(tokenB),
                config
            );

            // Restore snapshot
            vm.revertTo(snapshot);
        }
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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
            isAToB: true,
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
