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
import { PeggedSwap } from "../../src/instructions/PeggedSwap.sol";
import { FeeFlatIn, FeeFlatOut } from "../../src/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";
import { FeeProgressiveIn, FeeProgressiveOut } from "../../src/instructions/FeeProgressive.sol";

import { ProtocolFeeProviderMock } from "../../mocks/ProtocolFeeProviderMock.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title FeeConfig
 * @notice Configuration for all fee types. Zero value means fee is disabled.
 */
struct FeeConfig {
    uint24 flatFeeInBps;
    uint24 flatFeeOutBps;
    uint24 progressiveFeeInBps;
    uint24 progressiveFeeOutBps;
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
contract PeggedFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
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

    // Progressive fees
    uint24 internal progressiveFeeInBps = 0.1e7;   // 10%
    uint24 internal progressiveFeeOutBps = 0.1e7;  // 10%

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
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

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
        SwapVM _swapVM,
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
            (fees.progressiveFeeInBps > 0) ? FeeProgressiveIn.build(fees.progressiveFeeInBps) : bytes(""),
            (fees.progressiveFeeOutBps > 0) ? FeeProgressiveOut.build(fees.progressiveFeeOutBps) : bytes(""),

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
            progressiveFeeInBps: 0,
            progressiveFeeOutBps: 0,
            protocolFeeInBps: 0,
            protocolFeeOutBps: 0,
            dynamicFeeProvider: address(0),
            feeRecipient: feeRecipient
        });
    }

    // ====== Pegged Tests ======

    function test_Pegged() public {
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

    function test_PeggedProgressiveFeeIn() public {
        FeeConfig memory fees = _feeConfig();
        fees.progressiveFeeInBps = progressiveFeeInBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

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

    function test_PeggedProgressiveFeeOut() public {
        FeeConfig memory fees = _feeConfig();
        fees.progressiveFeeOutBps = progressiveFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

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

    function test_PeggedProtocolFee() public virtual {
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
    ) internal view returns (bytes memory) {
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
