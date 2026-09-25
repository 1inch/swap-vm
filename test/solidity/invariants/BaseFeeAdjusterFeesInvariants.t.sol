// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { SwapVM } from "../../../contracts/SwapVM.sol";
import { SwapVMRouter } from "../../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances } from "../../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../../contracts/instructions/LimitSwap.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../../contracts/instructions/DutchAuction.sol";
import { PiecewiseLinearSurchargeBalanceIn, PiecewiseLinearSurchargeBalanceOut } from "../../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../../../contracts/instructions/BaseFeeAdjuster.sol";
import { FeeFlatIn, FeeFlatOut } from "../../../contracts/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title BaseFeeAdjusterFeesInvariants
 * @notice Tests balance-based gas compensation with fee instructions
 */
contract BaseFeeAdjusterFeesInvariants is Test, OpcodesDebug, CoreInvariants {
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

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 2e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        TokenMock(tokenIn).mint(taker, amount * 10);
        (amountIn, amountOut,) = _swapVM.swap(order, amount, takerData);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with a flat input fee.
     */
    function test_BaseFeeAdjuster_FlatFeeIn() public {
        bytes memory bytecode = bytes.concat(
            _staticBalanceInSurcharge(),
            FeeFlatIn.build(0.01e7),
            BaseFeeAdjusterBalanceIn.build(20 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariantsWithConfig(bytecode, 150 gwei, false, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with a flat output fee.
     */
    function test_BaseFeeAdjuster_FlatFeeOut() public {
        bytes memory bytecode = bytes.concat(
            _staticBalanceOutSurcharge(),
            FeeFlatOut.build(0.02e7),
            BaseFeeAdjusterBalanceOut.build(25 gwei, 2500e18, 180_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariantsWithConfig(bytecode, 100 gwei, false, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with a protocol output fee.
     */
    function test_BaseFeeAdjuster_ProtocolFee() public {
        bytes memory bytecode = bytes.concat(
            _staticBalanceOutSurcharge(),
            FeeBuilders.protocolFeeOut(0.015e7, protocolFeeCollector),
            BaseFeeAdjusterBalanceOut.build(22 gwei, 3200e18, 155_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariantsWithConfig(bytecode, 180 gwei, true, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with multiple fees.
     */
    function test_BaseFeeAdjuster_MultipleFees() public {
        bytes memory bytecode = bytes.concat(
            _staticBalanceInSurcharge(),
            FeeFlatIn.build(0.005e7),
            FeeBuilders.protocolFeeOut(0.01e7, protocolFeeCollector),
            BaseFeeAdjusterBalanceIn.build(20 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariantsWithConfig(bytecode, 150 gwei, true, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with a high flat fee.
     */
    function test_BaseFeeAdjuster_HighFees() public {
        bytes memory bytecode = bytes.concat(
            _staticBalanceInSurcharge(),
            FeeFlatIn.build(0.1e7),
            BaseFeeAdjusterBalanceIn.build(20 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariantsWithConfig(bytecode, 200 gwei, false, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with DutchAuctionBalanceIn and a flat input fee.
     */
    function test_BaseFeeAdjuster_DutchAuctionIn_FlatFeeIn() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, 0.999e18, 0.5e7),
            FeeFlatIn.build(0.01e7),
            BaseFeeAdjusterBalanceIn.build(25 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariantsWithConfig(bytecode, 200 gwei, false, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with DutchAuctionBalanceOut and a flat output fee.
     */
    function test_BaseFeeAdjuster_DutchAuctionOut_FlatFeeOut() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, 0.999e18, 0.5e7),
            FeeFlatOut.build(0.015e7),
            BaseFeeAdjusterBalanceOut.build(25 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariantsWithConfig(bytecode, 200 gwei, false, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with DutchAuctionBalanceIn and a protocol fee.
     */
    function test_BaseFeeAdjuster_DutchAuctionIn_ProtocolFee() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, 0.999e18, 0.5e7),
            FeeBuilders.protocolFeeOut(0.02e7, protocolFeeCollector),
            BaseFeeAdjusterBalanceIn.build(30 gwei, 2800e18, 100_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariantsWithConfig(bytecode, 100 gwei, true, false, false);
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with DutchAuctionBalanceOut and multiple fees.
     */
    function test_BaseFeeAdjuster_DutchAuctionOut_MultipleFees() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, 0.999e18, 0.5e7),
            FeeFlatIn.build(0.0075e7),
            FeeBuilders.protocolFeeOut(0.01e7, protocolFeeCollector),
            BaseFeeAdjusterBalanceOut.build(25 gwei, 3200e18, 160_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariantsWithConfig(bytecode, 200 gwei, true, false, false);
    }

    function _staticBalanceInSurcharge() private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 22);
        scales[1] = uint24(1 << 22);

        return bytes.concat(
            StaticBalances.build(1e30, 2e30),
            PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales)
        );
    }

    function _staticBalanceOutSurcharge() private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 22);
        scales[1] = uint24(1 << 22);

        return bytes.concat(
            StaticBalances.build(1e30, 2e30),
            PiecewiseLinearSurchargeBalanceOut.build(uint40(block.timestamp), durations, scales)
        );
    }

    function _testInvariantsWithConfig(
        bytes memory bytecode,
        uint256 gasPrice,
        bool skipAdditivity,
        bool skipSymmetry,
        bool skipMonotonicity
    ) private {
        ISwapVM.Order memory order = _createOrder(bytecode);
        vm.fee(gasPrice);

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;
        testAmounts[1] = 5000e18;
        testAmounts[2] = 10000e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 100);
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        config.skipAdditivity = skipAdditivity;
        config.skipSymmetry = skipSymmetry;
        config.skipMonotonicity = skipMonotonicity;
        config.monotonicityToleranceBps = 1;
        config.roundingToleranceBps = 1000;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
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
