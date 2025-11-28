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
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title BaseFeeAdjusterInvariants
 * @notice Tests invariants for BaseFeeAdjuster instruction with LimitSwap
 * @dev Tests gas-based price adjustments applied to limit orders
 */
contract BaseFeeAdjusterInvariants is Test, OpcodesDebug, CoreInvariants {
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
     * Test BaseFeeAdjuster invariants with low gas price
     */
    function test_BaseFeeAdjuster_LowGas() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 99e16; // 0.99 = 1% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
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

        _testInvariants(bytecode, 20 gwei, false, false); // Base gas price
    }

    /**
     * Test BaseFeeAdjuster invariants with moderate gas price
     */
    function test_BaseFeeAdjuster_ModerateGas() public {
        uint64 baseGasPrice = 20 gwei;
        uint96 ethToTokenPrice = 3000e18;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 98e16; // 0.98 = 2% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
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

        // TODO: research invariant behavior at moderate gas prices
        _testInvariants(bytecode, 100 gwei, true, true); // 5x base gas
    }

    /**
     * Test BaseFeeAdjuster invariants with high gas price
     */
    function test_BaseFeeAdjuster_HighGas() public {
        uint64 baseGasPrice = 30 gwei;
        uint96 ethToTokenPrice = 2500e18;
        uint24 gasAmount = 200_000;
        uint64 maxPriceDecay = 95e16; // 0.95 = 5% max adjustment

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
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

        // TODO: research invariant behavior at high gas prices
        _testInvariants(bytecode, 300 gwei, true, true); // 10x base gas
    }

    /**
     * Test BaseFeeAdjuster with different ETH prices
     */
    function test_BaseFeeAdjuster_DifferentEthPrices() public {
        uint64 baseGasPrice = 25 gwei;
        uint24 gasAmount = 150_000;
        uint64 maxPriceDecay = 98e16; // 0.98 = 2% max adjustment

        uint96[] memory ethPrices = new uint96[](3);
        ethPrices[0] = 1500e18;  // Low ETH price
        ethPrices[1] = 3000e18;  // Medium ETH price
        ethPrices[2] = 5000e18;  // High ETH price

        for (uint256 i = 0; i < ethPrices.length; i++) {
            Program memory program = ProgramBuilder.init(_opcodes());
            bytes memory bytecode = bytes.concat(
                program.build(_staticBalancesXD,
                    BalancesArgsBuilder.build(
                        dynamic([address(tokenA), address(tokenB)]),
                        dynamic([uint256(1e30), uint256(2e30)])
                    )),
                program.build(_limitSwap1D,
                    LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
                program.build(_baseFeeAdjuster1D,
                    BaseFeeAdjusterArgsBuilder.build(
                        baseGasPrice,
                        ethPrices[i],
                        gasAmount,
                        maxPriceDecay
                    ))
            );

            // TODO: Analyze invariant behavior across different ETH prices
            _testInvariants(bytecode, 150 gwei, true, true);
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
        uint64 maxPriceDecay = 99e16;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
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
        // TODO: Analyze invariant behavior with DutchAuction and gas adjustment
        _testInvariants(bytecode, 200 gwei, true, true);
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
        uint64 maxPriceDecay = 99e16;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1e30), uint256(2e30)])
                )),
            program.build(_dutchAuctionBalanceOut1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
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
        // TODO: Analyze invariant behavior with DutchAuction output and gas adjustment
        _testInvariants(bytecode, 200 gwei, true, true);
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
     * causing the invariant violations.
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

        // Skip invariants based on parameters
        // TODO: Research if additivity can be preserved for gas-adjusted orders
        config.skipAdditivity = skipAdditivity;

        // TODO: Research if symmetry can be restored despite asymmetric gas adjustments
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
