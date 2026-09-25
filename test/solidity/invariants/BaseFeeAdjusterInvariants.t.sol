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
import { PiecewiseLinearSurchargeBalanceIn } from "../../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../../../contracts/instructions/BaseFeeAdjuster.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title BaseFeeAdjusterInvariants
 * @notice Tests invariants for balance-based gas compensation with LimitSwap
 */
contract BaseFeeAdjusterInvariants is Test, OpcodesDebug, CoreInvariants {
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
     * Test BaseFeeAdjuster invariants at the base gas price.
     */
    function test_BaseFeeAdjuster_LowGas() public {
        bytes memory bytecode = _buildBalanceInProgram(20 gwei, 3000e18, 150_000);
        _testInvariants(bytecode, 20 gwei);
    }

    /**
     * Test BaseFeeAdjuster invariants at a moderate gas price.
     */
    function test_BaseFeeAdjuster_ModerateGas() public {
        bytes memory bytecode = _buildBalanceInProgram(20 gwei, 3000e18, 150_000);
        _testInvariants(bytecode, 100 gwei);
    }

    /**
     * Test BaseFeeAdjuster invariants at a high gas price.
     */
    function test_BaseFeeAdjuster_HighGas() public {
        bytes memory bytecode = _buildBalanceInProgram(30 gwei, 2500e18, 200_000);
        _testInvariants(bytecode, 300 gwei);
    }

    /**
     * Test BaseFeeAdjuster with different ETH prices.
     */
    function test_BaseFeeAdjuster_DifferentEthPrices() public {
        uint96[] memory ethPrices = new uint96[](3);
        ethPrices[0] = 1500e18;
        ethPrices[1] = 3000e18;
        ethPrices[2] = 5000e18;

        for (uint256 i = 0; i < ethPrices.length; i++) {
            _testInvariants(_buildBalanceInProgram(25 gwei, ethPrices[i], 150_000), 150 gwei);
        }
    }

    /**
     * Test BaseFeeAdjusterBalanceIn with DutchAuctionBalanceIn.
     */
    function test_BaseFeeAdjuster_WithDutchAuctionIn() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, 0.999e18, 0.5e7),
            BaseFeeAdjusterBalanceIn.build(25 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariants(bytecode, 200 gwei);
    }

    /**
     * Test BaseFeeAdjusterBalanceOut with DutchAuctionBalanceOut.
     */
    function test_BaseFeeAdjuster_WithDutchAuctionOut() public {
        uint40 startTime = uint40(block.timestamp);
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, 0.999e18, 0.5e7),
            BaseFeeAdjusterBalanceOut.build(25 gwei, 3000e18, 150_000),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        vm.warp(startTime + 150);
        _testInvariants(bytecode, 200 gwei);
    }

    function _buildBalanceInProgram(
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) private view returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 22);
        scales[1] = uint24(1 << 22);

        return bytes.concat(
            StaticBalances.build(1e30, 2e30),
            PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethPrice, gasAmount),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    /**
     * The adjuster changes virtual balances before LimitSwap, so linear-rate
     * symmetry and additivity remain valid at every gas price.
     */
    function _testInvariants(bytes memory bytecode, uint256 gasPrice) private {
        ISwapVM.Order memory order = _createOrder(bytecode);
        vm.fee(gasPrice);

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;
        testAmounts[1] = 5000e18;
        testAmounts[2] = 10000e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 100);
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
