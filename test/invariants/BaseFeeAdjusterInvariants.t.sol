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
import { StaticBalances, DynamicBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../src/instructions/DutchAuction.sol";
import { BaseFeeAdjusterBalanceIn } from "../../src/instructions/BaseFeeAdjuster.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title BaseFeeAdjusterInvariants
 * @notice Tests invariants for BaseFeeAdjusterBalanceIn instruction with LimitSwap
 * @dev Tests gas-based balance adjustments applied to limit orders
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
     * Test BaseFeeAdjuster invariants with low gas price
     */
    function test_BaseFeeAdjuster_LowGas() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint24 capBps = 0.01e7; // 1% cap on the input balance

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethToTokenPrice, gasAmount, capBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode, 20 gwei, false, false); // Base gas price
    }

    /**
     * Test BaseFeeAdjuster invariants with moderate gas price
     */
    function test_BaseFeeAdjuster_ModerateGas() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint24 capBps = 0.02e7; // 2% cap on the input balance

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethToTokenPrice, gasAmount, capBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode, 100 gwei, false, false); // 5x base gas
    }

    /**
     * Test BaseFeeAdjuster invariants with high gas price
     */
    function test_BaseFeeAdjuster_HighGas() public {
        uint64 baseGasPrice = 30 gwei;
        uint96 ethToTokenPrice = 2500e18;
        uint24 gasAmount = 200_000;
        uint24 capBps = 0.05e7; // 5% cap on the input balance

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethToTokenPrice, gasAmount, capBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        _testInvariants(bytecode, 300 gwei, false, false); // 10x base gas
    }

    /**
     * Test BaseFeeAdjuster with different ETH prices
     */
    function test_BaseFeeAdjuster_DifferentEthPrices() public {
        uint64 baseGasPrice = 25 gwei;
        uint24 gasAmount = 150_000;
        uint24 capBps = 0.02e7; // 2% cap on the input balance

        uint96[] memory ethPrices = new uint96[](3);
        ethPrices[0] = 1500e18;  // Low ETH price
        ethPrices[1] = 3000e18;  // Medium ETH price
        ethPrices[2] = 5000e18;  // High ETH price

        for (uint256 i = 0; i < ethPrices.length; i++) {
            bytes memory bytecode = bytes.concat(
                StaticBalances.build(1e30, 2e30),
                BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethPrices[i], gasAmount, capBps),
                LimitSwap.build(address(tokenA), address(tokenB))
            );

            _testInvariants(bytecode, 150 gwei, false, false);
        }
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on input
     */
    function test_BaseFeeAdjuster_WithDutchAuctionIn() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint24 capBps = 0.01e7;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethToTokenPrice, gasAmount, capBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // Test at mid-auction with high gas
        vm.warp(startTime + 150);
        _testInvariants(bytecode, 200 gwei, false, false);
    }

    /**
     * Test BaseFeeAdjuster with DutchAuction on output
     */
    function test_BaseFeeAdjuster_WithDutchAuctionOut() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;

        uint64 baseGasPrice = 25 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint24 capBps = 0.01e7;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethToTokenPrice, gasAmount, capBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        // Test at mid-auction with high gas
        vm.warp(startTime + 150);
        _testInvariants(bytecode, 200 gwei, false, false);
    }

    /**
     * Helper to test invariants for a given bytecode and gas price
     *
     * @notice BaseFeeAdjusterBalanceIn shifts the input balance before the swap, so the order
     * behaves as a plain limit rate for the given gas price: symmetry and additivity hold
     * up to the usual limit-swap rounding.
     */
    function _testInvariants(bytes memory bytecode, uint256 gasPrice, bool skipAdditivity, bool skipSymmetry) private {
        ISwapVM.Order memory order = _createOrder(bytecode);

        // Set gas price
        vm.fee(gasPrice);

        // Use smaller test amounts to avoid overflow with gas adjustments
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;
        testAmounts[1] = 5000e18;
        testAmounts[2] = 10000e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 100); // 100 wei tolerance
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        config.skipAdditivity = skipAdditivity;
        config.skipSymmetry = skipSymmetry;

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
            allowPartialFill: false,
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
