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
import { FeeFlatIn, FeeFlatOut } from "../../../contracts/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";
import { XYCSwap } from "../../../contracts/instructions/XYCSwap.sol";

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
    uint24 protocolFeeOutBps;
    uint24 protocolFeeInBps;
    address dynamicFeeProvider;
    address feeRecipient;
}


/**
 * @title XYCFeesInvariants
 * @notice Tests invariants for XYCSwap and SwapVMRouter under all supported fee configurations
 * @dev Tests pool liquidity behavior with different fee structures applied to XYC pairs
 */
contract XYCFeesInvariants is Test, CoreInvariants {
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

    // Flat fees
    uint24 internal flatFeeInBps = 0.003e7;    // 0.3%
    uint24 internal flatFeeOutBps = 0.005e7;   // 0.5%

    // Protocol fee
    uint24 internal protocolFeeOutBps = 0.002e7;   // 0.2%
    address internal feeRecipient = address(0xFEE);

    // Test amounts for invariants
    uint256[] internal testAmounts;

    // Test amounts for exactOut (if empty, uses testAmounts)
    // Needed for imbalanced pools where exactOut amounts must be < balanceB
    uint256[] internal testAmountsExactOut;

    // Symmetry tolerance (default 2 wei, increase for imbalanced pools)
    uint256 internal symmetryTolerance = 2;

    // Additivity tolerance (default 0, increase for rounding in extreme pools)
    uint256 internal additivityTolerance = 0;

    // Rounding tolerance in bps (default 100 = 1%, increase for imbalanced pools with high fees)
    uint256 internal roundingToleranceBps = 100;

    // Skip flags for edge cases
    bool internal skipMonotonicity = false;  // Skip for dust amounts where rounding > price impact
    bool internal skipSpotPrice = false;     // Skip for dust amounts where rate > spot

    // Monotonicity tolerance in bps (default 0, strict; increase for dust where rounding > price impact)
    uint256 internal monotonicityToleranceBps = 0;

    function setUp() public virtual {
        maker = vm.addr(makerPK);
        taker = address(this);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup tokens and approvals for maker (mint max for huge liquidity tests)
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
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
        // Calculate mint amount based on pool imbalance ratio and fee multiplier
        // For imbalanced pools (e.g., 10000:100), need more tokens
        uint256 maxBalance = balanceA > balanceB ? balanceA : balanceB;
        uint256 minBalance = balanceA < balanceB ? balanceA : balanceB;
        uint256 imbalanceRatio = minBalance > 0 ? (maxBalance / minBalance) + 1 : 1;

        // Account for high fees (e.g., 99.9% fee means 1000x more tokens needed for exactOut)
        uint256 maxFee = flatFeeInBps > flatFeeOutBps ? flatFeeInBps : flatFeeOutBps;
        uint256 feeMultiplier = maxFee > 0 ? (1e7 / (1e7 - maxFee)) + 1 : 1;

        uint256 multiplier = imbalanceRatio > feeMultiplier ? imbalanceRatio : feeMultiplier;
        uint256 mintAmount = amount * 10 * (multiplier > 10 ? multiplier : 10);

        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, mintAmount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    // ====== Universal Program Builder ======

    /**
     * @notice Builds bytecode program with specified balances and fees
     * @param _balanceA Balance of token A
     * @param _balanceB Balance of token B
     * @param fees Fee configuration (0 = disabled)
     */
    function _buildProgram(
        uint256 _balanceA,
        uint256 _balanceB,
        FeeConfig memory fees
    ) internal view returns (bytes memory) {
        return bytes.concat(
            // Protocol fees BEFORE balances
            (fees.protocolFeeOutBps > 0) ? FeeBuilders.protocolFeeOut(fees.protocolFeeOutBps, fees.feeRecipient) : bytes(""),

            // Dynamic protocol fee on amountIn BEFORE balances
            (fees.dynamicFeeProvider != address(0)) ? FeeBuilders.protocolProviderIn(fees.dynamicFeeProvider) : bytes(""),

            // Protocol fee on amountIn BEFORE balances
            (fees.protocolFeeInBps > 0) ? FeeBuilders.protocolFeeIn(fees.protocolFeeInBps, fees.feeRecipient) : bytes(""),

            // Balances
            DynamicBalances.build(_balanceA, _balanceB),

            // Regular fees AFTER balances (0 = disabled)
            (fees.flatFeeInBps > 0) ? FeeFlatIn.build(fees.flatFeeInBps) : bytes(""),
            (fees.flatFeeOutBps > 0) ? FeeFlatOut.build(fees.flatFeeOutBps) : bytes(""),

            // Swap instruction
            XYCSwap.build()
        );
    }

    function _config(ISwapVM.Order memory order) internal view returns (InvariantConfig memory) {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = testAmounts;
        config.testAmountsExactOut = testAmountsExactOut;  // Use separate exactOut amounts if set
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
            protocolFeeOutBps: 0,
            protocolFeeInBps: 0,
            dynamicFeeProvider: address(0),
            feeRecipient: feeRecipient
        });
    }

    // ====== XYC Tests ======

    function test_XYC() public {
        _run_test_XYC();
    }

    function _run_test_XYC() internal {
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

    /**
     * Test XYC with flat fee on input
     */
    function test_XYCFlatFeeIn() public {
        _run_test_XYCFlatFeeIn();
    }

    function _run_test_XYCFlatFeeIn() internal {
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

    /**
     * Test XYC with flat fee on output (using feeOutAsIn to preserve additivity)
     */
    function test_XYCFlatFeeOut() public {
        _run_test_XYCFlatFeeOut();
    }

    function _run_test_XYCFlatFeeOut() internal {
        FeeConfig memory fees = _feeConfig();
        fees.flatFeeOutBps = flatFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // FlatFeeOut violates additivity by design (non-linear fee calculation)
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
     * Test  + XYC with protocol fee
     */
    function test_XYCProtocolFee() public virtual {
        _run_test_XYCProtocolFee();
    }

    function _run_test_XYCProtocolFee() internal {
        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        FeeConfig memory fees = _feeConfig();
        fees.protocolFeeOutBps = protocolFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test multiple fee types with  + XYC
     */
    function test_XYCMultipleFees() public {
        _run_test_XYCMultipleFees();
    }

    function _run_test_XYCMultipleFees() internal {
        FeeConfig memory fees = _feeConfig();
        fees.flatFeeInBps = flatFeeInBps;
        fees.flatFeeOutBps = flatFeeOutBps;
        fees.protocolFeeOutBps = protocolFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // TODO: Fee out violate additivity
        config.skipAdditivity = true;
        // TODO: Multiple fees combined may cause rounding that violates symmetry
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
     * Test XYC with protocol fee on amountIn
     * @notice Tests the _protocolFeeAmountInXD instruction that charges fee from input amount
     */
    function test_XYCProtocolFeeIn() public virtual {
        _run_test_XYCProtocolFeeIn();
    }

    function _run_test_XYCProtocolFeeIn() internal {
        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        FeeConfig memory fees = _feeConfig();
        fees.protocolFeeInBps = protocolFeeOutBps;  // Use same rate for comparison
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test XYC with dynamic protocol fee on amountIn
     * @notice Tests the _dynamicProtocolFeeAmountInXD instruction that queries fee from provider
     */
    function test_XYCDynamicProtocolFeeIn() public virtual {
        _run_test_XYCDynamicProtocolFeeIn();
    }

    function _run_test_XYCDynamicProtocolFeeIn() internal {
        // Deploy fee provider with 0.2% fee
        ProtocolFeeProviderMock feeProvider = new ProtocolFeeProviderMock(
            protocolFeeOutBps,
            0,
            feeRecipient,
            address(this)
        );

        FeeConfig memory fees = _feeConfig();
        fees.dynamicFeeProvider = address(feeProvider);
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // Dynamic protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = 1;

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

    function _runAllFeeVariants() internal {
        _run_test_XYC();
        _run_test_XYCFlatFeeIn();
        _run_test_XYCFlatFeeOut();
        _run_test_XYCProtocolFee();
        _run_test_XYCMultipleFees();
        _run_test_XYCProtocolFeeIn();
        _run_test_XYCDynamicProtocolFeeIn();
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
        additivityTolerance = 1;
        _runAllFeeVariants();
    }

    function test_DustAmounts() public {
        flatFeeOutBps = 0.003e7;
        testAmounts = new uint256[](9);
        testAmounts[0] = 5;
        testAmounts[1] = 7;
        testAmounts[2] = 10;
        testAmounts[3] = 20;
        testAmounts[4] = 50;
        testAmounts[5] = 100;
        testAmounts[6] = 1000;
        testAmounts[7] = 10000;
        testAmounts[8] = 100000;
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;
        testAmountsExactOut[1] = 10;
        testAmountsExactOut[2] = 100;
        testAmountsExactOut[3] = 1000;
        testAmountsExactOut[4] = 10000;
        testAmountsExactOut[5] = 100000;
        symmetryTolerance = 1;
        additivityTolerance = 0;
        monotonicityToleranceBps = 5000;
        _runAllFeeVariants();
    }

    function test_HugeLiquidity() public {
        balanceA = 1e24;
        balanceB = 1e24;
        flatFeeOutBps = 0.003e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e21;
        testAmounts[1] = 1e22;
        testAmounts[2] = 1e23;
        additivityTolerance = 1;
        _runAllFeeVariants();
    }

    function test_ImbalancedPoolHighFees() public {
        balanceA = 10000e18;
        balanceB = 100e18;
        flatFeeInBps = 0.01e7;
        flatFeeOutBps = 0.01e7;
        protocolFeeOutBps = 0.05e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 5e18;
        testAmountsExactOut[1] = 10e18;
        testAmountsExactOut[2] = 20e18;
        symmetryTolerance = 100;
        additivityTolerance = 1;
        roundingToleranceBps = 600;
        _runAllFeeVariants();
    }

    function test_ImbalancedPoolLowFees() public {
        balanceA = 10000e18;
        balanceB = 100e6;
        flatFeeInBps = 0.0001e7;
        flatFeeOutBps = 0.0001e7;
        protocolFeeOutBps = 0.001e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 5e6;
        testAmountsExactOut[1] = 10e6;
        testAmountsExactOut[2] = 20e6;
        symmetryTolerance = 1e15;
        additivityTolerance = 1;
        _runAllFeeVariants();
    }

    function test_LargeAmounts() public {
        flatFeeOutBps = 0.003e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;
        testAmounts[1] = 200e18;
        testAmounts[2] = 300e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 100e18;
        testAmountsExactOut[1] = 150e18;
        testAmountsExactOut[2] = 200e18;
        additivityTolerance = 1;
        _runAllFeeVariants();
    }

    function test_SmallAmounts() public {
        flatFeeOutBps = 0.003e7;
        testAmounts = new uint256[](4);
        testAmounts[0] = 1e12;
        testAmounts[1] = 1e14;
        testAmounts[2] = 1e15;
        testAmounts[3] = 1e16;
        additivityTolerance = 1;
        _runAllFeeVariants();
    }

    function test_TinyLiquidity() public {
        tokenA = new TokenMockDecimals("Token I", "TKI", 6);
        tokenB = new TokenMockDecimals("Token J", "TKJ", 6);
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        TokenMockDecimals(address(tokenA)).mint(maker, type(uint128).max);
        TokenMockDecimals(address(tokenB)).mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        balanceA = 1000e6;
        balanceB = 1000e6;
        flatFeeOutBps = 0.003e7;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e5;
        testAmounts[1] = 1e6;
        testAmounts[2] = 10e6;
        additivityTolerance = 1;
        _runAllFeeVariants();
    }
}
