// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "../helpers/SwapVMTestSetup.sol";
import { StaticBalances, DynamicBalances } from "../../../contracts/instructions/Balances.sol";
import { PeggedSwap } from "../../../contracts/instructions/PeggedSwap.sol";
import { FeeFlatIn, FeeFlatOut } from "../../../contracts/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";

import { ProtocolFeeProviderMock } from "../../../contracts/mocks/ProtocolFeeProviderMock.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";
import { TokenMockDecimals } from "../mocks/TokenMockDecimals.sol";


/**
 * @title FeeConfig
 * @notice Configuration for all fee types. Zero value means fee is disabled.
 */
struct FeeConfig {
    uint24 flatFeeInBps;
    uint24 flatFeeOutBps;
    uint24 protocolFeeInBps;
    uint24 protocolFeeOutBps;
    address dynamicFeeProvider;
    address feeRecipient;
}


/**
 * @title PeggedFeesInvariants
 * @notice Tests invariants for PeggedSwap + all types of fees
 * @dev Tests pegged curve with different fee structures
 */
contract PeggedFeesInvariants is Test, CoreInvariants {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    // ====== Storage Variables for Inheritance ======

    // Pool balances
    uint256 internal balanceA = 1000e18;
    uint256 internal balanceB = 1000e18;

    // PeggedSwap config (using 1e27 scale for x0/y0/linearWidth to match PeggedSwapMath.ONE)
    uint256 internal x0 = 1000e18;        // Initial X reserve (normalization)
    uint256 internal y0 = 1000e18;        // Initial Y reserve (normalization)
    uint256 internal linearWidth = 0.8e27; // A parameter (0.8 = mostly linear)
    uint256 internal rateLt = 1;        // Rate for lower address token (scales 1e18 -> 1e27)
    uint256 internal rateGt = 1;        // Rate for greater address token (scales 1e18 -> 1e27)

    // Flat fees
    uint24 internal flatFeeInBps = 0.003e7;    // 0.3%
    uint24 internal flatFeeOutBps = 0.005e7;   // 0.5%

    // Protocol fee
    uint24 internal protocolFeeOutBps = 0.002e7;   // 0.2%
    address internal feeRecipient = address(0xFEE);

    // Test amounts for invariants
    uint256[] internal testAmounts;

    // Test amounts for exactOut (if empty, uses testAmounts)
    uint256[] internal testAmountsExactOut;

    // Symmetry tolerance (default 2 wei, increase for nondivisible x0/y0)
    // NOTE: For x0/y0 not divisible by 1e18 (e.g., 1500e18), error ≈ x0/1e18 wei
    uint256 internal symmetryTolerance = 2;

    // Additivity tolerance (default 0, increase for rounding)
    uint256 internal additivityTolerance = 0;

    // Rounding tolerance in bps (default 100 = 1%)
    uint256 internal roundingToleranceBps = 100;

    // Skip flags for edge cases
    bool internal skipMonotonicity = false;
    bool internal skipSpotPrice = false;

    // Monotonicity tolerance in bps
    uint256 internal monotonicityToleranceBps = 0;

    function setUp() public virtual {
        maker = vm.addr(makerPK);
        taker = address(this);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup tokens and approvals for maker
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Default test amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 20e18;
        testAmounts[2] = 50e18;
    }

    /**
     * @notice Implementation of _executeSwap for real swap execution
     */
    function _executeSwap(
        SwapVMRouter _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        uint256 maxBalance = balanceA > balanceB ? balanceA : balanceB;
        uint256 minBalance = balanceA < balanceB ? balanceA : balanceB;
        uint256 imbalanceRatio = minBalance > 0 ? (maxBalance / minBalance) + 1 : 1;

        uint256 maxFee = flatFeeInBps > flatFeeOutBps ? flatFeeInBps : flatFeeOutBps;
        uint256 feeMultiplier = maxFee > 0 ? (1e7 / (1e7 - maxFee)) + 1 : 1;

        uint256 multiplier = imbalanceRatio > feeMultiplier ? imbalanceRatio : feeMultiplier;
        uint256 mintAmount = amount * 10 * (multiplier > 10 ? multiplier : 10);

        TokenMock(tokenIn).mint(taker, mintAmount);

        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    // ====== Universal Program Builder ======

    function _buildProgram(
        uint256 _balanceA,
        uint256 _balanceB,
        FeeConfig memory fees
    ) internal view returns (bytes memory) {
        return bytes.concat(
            // Protocol fees BEFORE balances
            (fees.protocolFeeOutBps > 0) ? FeeBuilders.protocolFeeOut(fees.protocolFeeOutBps, fees.feeRecipient) : bytes(""),
            (fees.protocolFeeInBps > 0) ? FeeBuilders.protocolFeeIn(fees.protocolFeeInBps, fees.feeRecipient) : bytes(""),
            (fees.dynamicFeeProvider != address(0)) ? FeeBuilders.protocolProviderIn(fees.dynamicFeeProvider) : bytes(""),

            // Balances
            DynamicBalances.build(_balanceA, _balanceB),

            // Regular fees AFTER balances
            (fees.flatFeeInBps > 0) ? FeeFlatIn.build(fees.flatFeeInBps) : bytes(""),
            (fees.flatFeeOutBps > 0) ? FeeFlatOut.build(fees.flatFeeOutBps) : bytes(""),

            // PeggedSwap instruction
            PeggedSwap.build(x0, y0, linearWidth, rateLt, rateGt)
        );
    }

    function _config(ISwapVM.Order memory order) internal view returns (InvariantConfig memory) {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = testAmounts;
        config.testAmountsExactOut = testAmountsExactOut;
        config.symmetryTolerance = symmetryTolerance;
        config.additivityTolerance = additivityTolerance;
        config.roundingToleranceBps = roundingToleranceBps;
        config.skipMonotonicity = skipMonotonicity;
        config.skipSpotPrice = skipSpotPrice;
        config.monotonicityToleranceBps = monotonicityToleranceBps;
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        return config;
    }

    function _feeConfig() internal view returns (FeeConfig memory) {
        return FeeConfig({
            flatFeeInBps: 0,
            flatFeeOutBps: 0,
            protocolFeeInBps: 0,
            protocolFeeOutBps: 0,
            dynamicFeeProvider: address(0),
            feeRecipient: feeRecipient
        });
    }

    // ====== Pegged Tests ======

    function test_Pegged() public {
        _run_test_Pegged();
    }

    function _run_test_Pegged() internal {
        FeeConfig memory fees = _feeConfig();
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedFlatFeeIn() public {
        _run_test_PeggedFlatFeeIn();
    }

    function _run_test_PeggedFlatFeeIn() internal {
        FeeConfig memory fees = _feeConfig();
        fees.flatFeeInBps = flatFeeInBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedFlatFeeOut() public {
        _run_test_PeggedFlatFeeOut();
    }

    function _run_test_PeggedFlatFeeOut() internal {
        FeeConfig memory fees = _feeConfig();
        fees.flatFeeOutBps = flatFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // FlatFeeOut violates additivity by design
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedProtocolFee() public virtual {
        _run_test_PeggedProtocolFee();
    }

    function _run_test_PeggedProtocolFee() internal {
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        FeeConfig memory fees = _feeConfig();
        fees.protocolFeeOutBps = protocolFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Use max of class additivityTolerance or minimum for protocol fee
        config.additivityTolerance = additivityTolerance > 1 ? additivityTolerance : 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedProtocolFeeIn() public virtual {
        _run_test_PeggedProtocolFeeIn();
    }

    function _run_test_PeggedProtocolFeeIn() internal {
        FeeConfig memory fees = _feeConfig();
        fees.protocolFeeInBps = protocolFeeOutBps; // Use same rate as protocolFeeOut
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = additivityTolerance > 1 ? additivityTolerance : 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedDynamicProtocolFeeIn() public virtual {
        _run_test_PeggedDynamicProtocolFeeIn();
    }

    function _run_test_PeggedDynamicProtocolFeeIn() internal {
        // Deploy fee provider with 0.2% fee
        ProtocolFeeProviderMock feeProviderMock = new ProtocolFeeProviderMock(
            protocolFeeOutBps,
            0,
            feeRecipient,
            address(this)
        );

        FeeConfig memory fees = _feeConfig();
        fees.dynamicFeeProvider = address(feeProviderMock);
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Dynamic protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = additivityTolerance > 1 ? additivityTolerance : 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function test_PeggedMultipleFees() public {
        _run_test_PeggedMultipleFees();
    }

    function _run_test_PeggedMultipleFees() internal {
        FeeConfig memory fees = _feeConfig();
        fees.flatFeeInBps = flatFeeInBps;
        fees.flatFeeOutBps = flatFeeOutBps;
        fees.protocolFeeOutBps = protocolFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        config.skipAdditivity = true;
        config.skipSymmetry = true;
        // Use configured tolerance (default 200, but can be overridden for different decimals)
        config.roundingToleranceBps = roundingToleranceBps > 200 ? roundingToleranceBps : 200;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // Helper functions
    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            threshold: thresholdData,
            to: address(this),
            hasPreTransferInCallback: false,
            signature: signature
        }));
    }

    function test_AsymmetricPool_ReverseSwap_NoAxisMismatch() public {
        _setupVeryImbalancedDifferentDecimals();

        uint256 abundantBalance = 100_000e18;
        uint256 scarceBalance = 10e6;

        bool tokenAIs18 = tokenA.decimals() == 18;

        uint256 balanceTokenA = tokenAIs18 ? abundantBalance : scarceBalance;
        uint256 balanceTokenB = tokenAIs18 ? scarceBalance : abundantBalance;
        uint256 rateLtTest = tokenAIs18 ? 1 : 1e12;
        uint256 rateGtTest = tokenAIs18 ? 1e12 : 1;
        uint256 x0Config = balanceTokenA * rateLtTest;
        uint256 y0Config = balanceTokenB * rateGtTest;

        bytes memory bytecode = bytes.concat(
            DynamicBalances.build(balanceTokenA, balanceTokenB),
            PeggedSwap.build(x0Config, y0Config, linearWidth, rateLtTest, rateGtTest)
        );

        ISwapVM.Order memory order = orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: bytecode
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 swapAmount = 1e18;
        uint256 swapAmountReverse = 1e6;

        address tokenInForward = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address tokenOutForward = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        if (balanceTokenA < balanceTokenB) {
            tokenInForward = address(tokenB);
            tokenOutForward = address(tokenA);
        }

        bytes memory exactInData = _reverseSwapTakerData(signature, tokenInForward < tokenOutForward);
        bytes memory exactInDataReverse = _reverseSwapTakerData(signature, tokenOutForward < tokenInForward);

        try swapVM.asView().quote(order, swapAmount, exactInData) returns (uint256, uint256 outForward, bytes32) {
            assertGt(outForward, 0, "Output should be non-zero");
            uint256 maxReasonableOutput = swapAmount * 20;
            uint256 outForwardScaled = outForward;
            if (tokenOutForward == address(tokenA) && balanceTokenA < balanceTokenB) {
                outForwardScaled = outForward * 1e12;
            } else if (tokenOutForward == address(tokenB) && balanceTokenB < balanceTokenA) {
                outForwardScaled = outForward * 1e12;
            }
            assertLe(
                outForwardScaled,
                maxReasonableOutput,
                string.concat(
                    "Reverse swap output wildly inflated - axis mismatch detected! ",
                    "Output: ", vm.toString(outForwardScaled),
                    ", Max reasonable: ", vm.toString(maxReasonableOutput)
                )
            );
        } catch {}

        try swapVM.asView().quote(order, swapAmountReverse, exactInDataReverse) returns (uint256, uint256 outReverse, bytes32) {
            assertGt(outReverse, 0, "Reverse output should be non-zero");
            uint256 outReverseScaled = outReverse;
            if (tokenInForward == address(tokenA) && balanceTokenA < balanceTokenB) {
                outReverseScaled = outReverse * 1e12;
            } else if (tokenInForward == address(tokenB) && balanceTokenB < balanceTokenA) {
                outReverseScaled = outReverse * 1e12;
            }
            uint256 normalizedInReverse = swapAmountReverse * 1e12;
            uint256 capacityRate = abundantBalance / (scarceBalance * 1e12);
            assertLe(
                outReverseScaled,
                normalizedInReverse * capacityRate * 2,
                "Reverse direction also should not have axis mismatch"
            );
        } catch {}
    }

    function _reverseSwapTakerData(bytes memory signature, bool isAToB) private view returns (bytes memory) {
        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: false,
            threshold: "",
            to: address(this),
            hasPreTransferInCallback: false,
            signature: signature
        }));
    }

    function _runAllFeeVariants() internal {
        _run_test_Pegged();
        _run_test_PeggedFlatFeeIn();
        _run_test_PeggedFlatFeeOut();
        _run_test_PeggedProtocolFee();
        _run_test_PeggedProtocolFeeIn();
        _run_test_PeggedDynamicProtocolFeeIn();
        _run_test_PeggedMultipleFees();
    }

    function test_BalancedCurve() public {
        linearWidth = 0.5e27;
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }

    function test_BalancedPoolEdgeFees() public {
        flatFeeInBps = 0.999e7;
        flatFeeOutBps = 0.001e7;
        protocolFeeOutBps = 0.1e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 0.1e18;
        testAmountsExactOut[1] = 0.5e18;
        testAmountsExactOut[2] = 1e18;
        symmetryTolerance = 2100;
        additivityTolerance = 2100;
        skipSpotPrice = true;
        _runAllFeeVariants();
    }

    function test_DustAmounts() public {
        testAmounts = new uint256[](3);
        testAmounts[0] = 1000;
        testAmounts[1] = 10000;
        testAmounts[2] = 1e12;
        skipMonotonicity = true;
        skipSpotPrice = true;
        symmetryTolerance = 3100;
        additivityTolerance = 100;
        _runAllFeeVariants();
    }

    function test_HugeLiquidity() public {
        balanceA = 1e27;
        balanceB = 1e27;
        x0 = 1e27;
        y0 = 1e27;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e24;
        testAmounts[1] = 1e25;
        testAmounts[2] = 1e26;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1e9;
        additivityTolerance = 2e9;
        _runAllFeeVariants();
    }

    function test_ImbalancedPoolHighFees() public {
        balanceA = 10000e18;
        balanceB = 1000e18;
        x0 = 10000e18;
        y0 = 1000e18;
        linearWidth = 0.5e27;
        flatFeeInBps = 0.05e7;
        flatFeeOutBps = 0.05e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 5e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 10e18;
        testAmountsExactOut[1] = 50e18;
        testAmountsExactOut[2] = 100e18;
        symmetryTolerance = 100;
        additivityTolerance = 10;
        roundingToleranceBps = 700;
        _runAllFeeVariants();
    }

    function test_ImbalancedPoolLowFees() public {
        balanceA = 10000e18;
        balanceB = 1000e18;
        x0 = 10000e18;
        y0 = 1000e18;
        linearWidth = 0.5e27;
        flatFeeInBps = 0.001e7;
        flatFeeOutBps = 0.001e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 5e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 10e18;
        testAmountsExactOut[1] = 50e18;
        testAmountsExactOut[2] = 100e18;
        symmetryTolerance = 100;
        _runAllFeeVariants();
    }

    function test_LargeAmounts() public {
        testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 300e18;
        testAmounts[2] = 500e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 50e18;
        testAmountsExactOut[1] = 100e18;
        testAmountsExactOut[2] = 200e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }

    function _setupVeryImbalancedDifferentDecimals() internal {
        TokenMock token18 = TokenMock(address(new TokenMockDecimals("Token I", "TKI", 18)));
        TokenMock token6 = TokenMock(address(new TokenMockDecimals("Token J", "TKJ", 6)));
        (tokenA, tokenB) = address(token18) < address(token6) ? (token18, token6) : (token6, token18);
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        if (address(token18) < address(token6)) {
            balanceA = 10e18;
            balanceB = 10e6;
            rateLt = 1;
            rateGt = 1e12;
        } else {
            balanceA = 10e6;
            balanceB = 10e18;
            rateLt = 1e12;
            rateGt = 1;
        }
        x0 = 10e18;
        y0 = 10e18;
        uint256 unitIn = address(token18) < address(token6) ? 1e18 : 1e6;
        uint256 unitOut = address(token18) < address(token6) ? 1e6 : 1e18;
        testAmounts = new uint256[](3);
        testAmounts[0] = unitIn / 10;
        testAmounts[1] = unitIn / 2;
        testAmounts[2] = unitIn;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = unitOut / 10;
        testAmountsExactOut[1] = unitOut / 2;
        testAmountsExactOut[2] = unitOut;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
        roundingToleranceBps = 400;
    }

    function test_LargeDifferentDecimals() public {
        TokenMock token18 = TokenMock(address(new TokenMockDecimals("Token I", "TKI", 18)));
        TokenMock token6 = TokenMock(address(new TokenMockDecimals("Token J", "TKJ", 6)));
        (tokenA, tokenB) = address(token18) < address(token6) ? (token18, token6) : (token6, token18);
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        if (address(token18) < address(token6)) {
            balanceA = 1_000_000e18;
            balanceB = 1_000_000e6;
            rateLt = 1;
            rateGt = 1e12;
        } else {
            balanceA = 1_000_000e6;
            balanceB = 1_000_000e18;
            rateLt = 1e12;
            rateGt = 1;
        }
        x0 = 1_000_000e18;
        y0 = 1_000_000e18;
        uint256 unitIn = address(token18) < address(token6) ? 1e18 : 1e6;
        uint256 unitOut = address(token18) < address(token6) ? 1e6 : 1e18;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1000 * unitIn;
        testAmounts[1] = 10_000 * unitIn;
        testAmounts[2] = 100_000 * unitIn;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1000 * unitOut;
        testAmountsExactOut[1] = 10_000 * unitOut;
        testAmountsExactOut[2] = 100_000 * unitOut;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
        _runAllFeeVariants();
    }

    function test_MostlyCurved() public {
        linearWidth = 0.2e27;
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }

    function test_PureSquareRoot() public {
        linearWidth = 0;
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }

    function test_SmallAmounts() public {
        testAmounts = new uint256[](3);
        testAmounts[0] = 0.01e18;
        testAmounts[1] = 0.1e18;
        testAmounts[2] = 1e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }

    function test_TinyLiquidity() public {
        balanceA = 1e18;
        balanceB = 1e18;
        x0 = 1e18;
        y0 = 1e18;
        testAmounts = new uint256[](3);
        testAmounts[0] = 0.01e18;
        testAmounts[1] = 0.05e18;
        testAmounts[2] = 0.1e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        roundingToleranceBps = 2500;
        _runAllFeeVariants();
    }

    function test_VeryImbalancedDifferentDecimals() public {
        _setupVeryImbalancedDifferentDecimals();
        _runAllFeeVariants();
    }

    function test_VeryLinear() public {
        linearWidth = 0.95e27;
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 50e18;
        testAmounts[2] = 100e18;
        flatFeeOutBps = 0.003e7;
        symmetryTolerance = 1010;
        additivityTolerance = 2000;
        _runAllFeeVariants();
    }
}
