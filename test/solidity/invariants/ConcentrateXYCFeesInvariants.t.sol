// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "../helpers/SwapVMTestSetup.sol";
import { StaticBalances, DynamicBalances } from "../../../contracts/instructions/Balances.sol";
import { FeeFlatIn, FeeFlatOut } from "../../../contracts/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";
import { XYCConcentrateSwap } from "../../../contracts/instructions/XYCConcentrate.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";
import { TokenMockDecimals } from "../mocks/TokenMockDecimals.sol";

/**
 * @title ConcentrateXYCFeesInvariants
 * @notice Tests invariants for XYCConcentrate + XYCSwap with fee configurations
 * @dev Tests concentrated liquidity AMM behavior with different fee structures
 */
contract ConcentrateXYCFeesInvariants is Test, CoreInvariants {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    // ====== Storage Variables for Inheritance ======

    // Liquidity available for providing (used to calculate initial balances)
    uint256 internal availableLiquidity = 1000e18;

    // Concentration price bounds (sqrtPriceMin, sqrtPriceMax)
    uint256 internal sqrtPriceMin = Math.sqrt(0.8e36);   // sqrt(0.8) in 1e18
    uint256 internal sqrtPriceMax = Math.sqrt(1.25e36);  // sqrt(1.25) in 1e18

    // Computed pool balances (derived from availableLiquidity and price bounds)
    uint256 internal balanceA;
    uint256 internal balanceB;

    // Flat fee
    uint24 internal flatFeeInBps = 0.003e7;    // 0.3%

    // Protocol fee
    uint24 internal protocolFeeOutBps = 0.002e7;   // 0.2%
    address internal feeRecipient = address(0xFEE);

    // Test amounts for invariants
    uint256[] internal testAmounts;

    // Test amounts for exactOut (if empty, uses testAmounts)
    uint256[] internal testAmountsExactOut;

    // Symmetry tolerance (default 2 wei)
    uint256 internal symmetryTolerance = 2;

    // Additivity tolerance (default 1 for concentrate due to L recalculation)
    uint256 internal additivityTolerance = 1;

    // Rounding tolerance in bps (default 10 = 0.1%)
    uint256 internal roundingToleranceBps = 10;

    // Skip flags for edge cases
    bool internal skipMonotonicity = false;
    bool internal skipSpotPrice = false;

    // Monotonicity tolerance in bps (default 0, strict)
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

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Compute initial balances from concentration parameters
        _computeInitialBalances();

        // Default test amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 20e18;
        testAmounts[2] = 50e18;
    }

    /**
     * @notice Compute initial pool balances based on concentration parameters
     * @dev Uses XYCConcentrateSwap.computeLiquidityFromAmounts
     */
    function _computeInitialBalances() internal {
        uint256 sqrtPspot = 1e18; // Market spot price = 1.0
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateSwap.computeLiquidityFromAmounts(
                availableLiquidity, availableLiquidity, sqrtPspot, sqrtPriceMin, sqrtPriceMax
            );

        // tokenA is Lt when address(tokenA) < address(tokenB)
        (balanceA, balanceB) = address(tokenA) < address(tokenB)
            ? (actualLt, actualGt)
            : (actualGt, actualLt);
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
        // Mint sufficient tokens for the swap
        uint256 mintAmount = amount * 10;
        TokenMock(tokenIn).mint(taker, mintAmount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    // ====== Program Builder ======

    /**
     * @notice Builds bytecode program with concentrate, balances and fees
     */
    function _buildConcentrateProgram(
        uint256 _balanceA,
        uint256 _balanceB,
        uint256 _sqrtPriceMin,
        uint256 _sqrtPriceMax,
        uint24 _flatFeeInBps,
        uint24 _protocolFeeOutBps
    ) internal view returns (bytes memory) {
        return bytes.concat(
            // Protocol fees BEFORE balances
            (_protocolFeeOutBps > 0) ? FeeBuilders.protocolFeeOut(_protocolFeeOutBps, feeRecipient) : bytes(""),

            // Balances
            DynamicBalances.build(_balanceA, _balanceB),

            // Flat fee BEFORE concentrate (concentrate is terminal)
            (_flatFeeInBps > 0) ? FeeFlatIn.build(_flatFeeInBps) : bytes(""),

            // Concentrate instruction (terminal: computes virtual reserves + swap)
            XYCConcentrateSwap.build(_sqrtPriceMin, _sqrtPriceMax)
        );
    }

    function _config(ISwapVM.Order memory order) internal view returns (InvariantConfig memory) {
        return _config(order, true);
    }

    function _config(ISwapVM.Order memory order, bool aToB) internal view returns (InvariantConfig memory) {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = testAmounts;
        config.testAmountsExactOut = testAmountsExactOut;
        config.symmetryTolerance = symmetryTolerance;
        config.additivityTolerance = additivityTolerance;
        config.roundingToleranceBps = roundingToleranceBps;
        config.skipMonotonicity = skipMonotonicity;
        config.skipSpotPrice = skipSpotPrice;
        config.monotonicityToleranceBps = monotonicityToleranceBps;
        config.exactInTakerData = _signAndPackTakerData(order, true, 0, aToB);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max, aToB);
        return config;
    }

    // ====== Concentrate Tests ======

    /**
     * @notice Test concentrate without fees
     */
    function test_ConcentrateXYC() public {
        _run_test_ConcentrateXYC();
    }

    function _run_test_ConcentrateXYC() internal {
        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
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
     * @notice Test concentrate with flat fee on input
     */
    function test_ConcentrateXYCFlatFeeIn() public {
        _run_test_ConcentrateXYCFlatFeeIn();
    }

    function _run_test_ConcentrateXYCFlatFeeIn() internal {
        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, flatFeeInBps, 0
        );
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
     * @notice Test concentrate with protocol fee
     */
    function test_ConcentrateXYCProtocolFee() public virtual {
        _run_test_ConcentrateXYCProtocolFee();
    }

    function _run_test_ConcentrateXYCProtocolFee() internal {
        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, protocolFeeOutBps
        );
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
     * @notice Test concentrate with multiple fees
     */
    function test_ConcentrateXYCMultipleFees() public {
        _run_test_ConcentrateXYCMultipleFees();
    }

    function _run_test_ConcentrateXYCMultipleFees() internal {
        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, flatFeeInBps, protocolFeeOutBps
        );
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
        return _signAndPackTakerData(order, isExactIn, threshold, true);
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold,
        bool aToB
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
            isAToB: aToB,
            allowPartialFill: false,
            threshold: thresholdData,
            to: address(this),
            hasPreTransferInCallback: false,
            signature: signature
        }));
    }

    function test_AsymmetricRangeUp() public {
        _setupEdgePriceRange();
        sqrtPriceMin = Math.sqrt(0.9e36);
        sqrtPriceMax = Math.sqrt(1.5e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order, false);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenB), address(tokenA), config);
    }

    function test_AsymmetricRangeDown() public {
        _setupEdgePriceRange();
        sqrtPriceMin = Math.sqrt(0.85e36);
        sqrtPriceMax = Math.sqrt(1.15e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_VeryNarrowRange() public {
        _setupEdgePriceRange();
        sqrtPriceMin = Math.sqrt(0.99e36);
        sqrtPriceMax = Math.sqrt(1.01e36);
        _computeInitialBalances();

        bytes memory bytecode = _buildConcentrateProgram(
            balanceA, balanceB, sqrtPriceMin, sqrtPriceMax, 0, 0
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function _runAllFeeVariants() internal {
        _run_test_ConcentrateXYC();
        _run_test_ConcentrateXYCFlatFeeIn();
        _run_test_ConcentrateXYCProtocolFee();
        _run_test_ConcentrateXYCMultipleFees();
    }

    function test_DustAmounts() public {
        testAmounts = new uint256[](8);
        testAmounts[0] = 3;
        testAmounts[1] = 10;
        testAmounts[2] = 20;
        testAmounts[3] = 50;
        testAmounts[4] = 100;
        testAmounts[5] = 500;
        testAmounts[6] = 1000;
        testAmounts[7] = 2000;
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;
        testAmountsExactOut[1] = 10;
        testAmountsExactOut[2] = 100;
        testAmountsExactOut[3] = 1000;
        testAmountsExactOut[4] = 10000;
        testAmountsExactOut[5] = 100000;
        symmetryTolerance = 1;
        additivityTolerance = 0;
        monotonicityToleranceBps = 15000;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function _setupEdgePriceRange() internal {
        testAmounts = new uint256[](4);
        testAmounts[0] = 1e18;
        testAmounts[1] = 10e18;
        testAmounts[2] = 50e18;
        testAmounts[3] = 100e18;
        symmetryTolerance = 0;
        additivityTolerance = 1;
        _computeInitialBalances();
    }

    function test_EdgePriceRange() public {
        _setupEdgePriceRange();
        _runAllFeeVariants();
    }

    function test_HugeLiquidity() public {
        availableLiquidity = 2.5e25;
        testAmounts = new uint256[](5);
        testAmounts[0] = 1e21;
        testAmounts[1] = 10e21;
        testAmounts[2] = 100e21;
        testAmounts[3] = 1e23;
        testAmounts[4] = 10e23;
        symmetryTolerance = 0;
        additivityTolerance = 1;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function test_LargeAmounts() public {
        testAmounts = new uint256[](5);
        testAmounts[0] = 50e18;
        testAmounts[1] = 100e18;
        testAmounts[2] = 150e18;
        testAmounts[3] = 200e18;
        testAmounts[4] = 250e18;
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 30e18;
        testAmountsExactOut[1] = 50e18;
        testAmountsExactOut[2] = 100e18;
        symmetryTolerance = 0;
        additivityTolerance = 1;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function test_MicroAmounts() public {
        testAmounts = new uint256[](8);
        testAmounts[0] = 2000;
        testAmounts[1] = 5000;
        testAmounts[2] = 10000;
        testAmounts[3] = 100000;
        testAmounts[4] = 1000000;
        testAmounts[5] = 10000000;
        testAmounts[6] = 100000000;
        testAmounts[7] = 1000000000;
        testAmountsExactOut = new uint256[](6);
        testAmountsExactOut[0] = 1;
        testAmountsExactOut[1] = 10;
        testAmountsExactOut[2] = 100;
        testAmountsExactOut[3] = 1000;
        testAmountsExactOut[4] = 10000;
        testAmountsExactOut[5] = 100000;
        symmetryTolerance = 2;
        additivityTolerance = 0;
        monotonicityToleranceBps = 4;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function test_NarrowRange() public {
        sqrtPriceMin = Math.sqrt(0.95e36);
        sqrtPriceMax = Math.sqrt(1.05e36);
        testAmounts = new uint256[](5);
        testAmounts[0] = 1e18;
        testAmounts[1] = 10e18;
        testAmounts[2] = 50e18;
        testAmounts[3] = 100e18;
        testAmounts[4] = 200e18;
        symmetryTolerance = 0;
        additivityTolerance = 1;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function test_SmallAmounts() public {
        testAmounts = new uint256[](5);
        testAmounts[0] = 0.01e18;
        testAmounts[1] = 0.1e18;
        testAmounts[2] = 0.5e18;
        testAmounts[3] = 1e18;
        testAmounts[4] = 5e18;
        symmetryTolerance = 1;
        additivityTolerance = 1;
        _computeInitialBalances();
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
        availableLiquidity = 1000e6;
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e5;
        testAmounts[1] = 1e6;
        testAmounts[2] = 10e6;
        additivityTolerance = 1;
        _computeInitialBalances();
        _runAllFeeVariants();
    }

    function test_WideRange() public {
        sqrtPriceMin = Math.sqrt(0.5e36);
        sqrtPriceMax = Math.sqrt(2.0e36);
        testAmounts = new uint256[](5);
        testAmounts[0] = 1e18;
        testAmounts[1] = 10e18;
        testAmounts[2] = 50e18;
        testAmounts[3] = 100e18;
        testAmounts[4] = 200e18;
        symmetryTolerance = 0;
        additivityTolerance = 1;
        _computeInitialBalances();
        _runAllFeeVariants();
    }
}
