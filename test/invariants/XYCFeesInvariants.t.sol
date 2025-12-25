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
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title FeeConfig
 * @notice Configuration for all fee types. Zero value means fee is disabled.
 */
struct FeeConfig {
    uint32 flatFeeInBps;
    uint32 flatFeeOutBps;
    uint32 progressiveFeeInBps;
    uint32 progressiveFeeOutBps;
    uint32 protocolFeeOutBps;
    address feeRecipient;
}


/**
 * @title XYCFeesInvariants
 * @notice Tests invariants for XYCSwap and SwapVM under all supported fee configurations
 * @dev Tests pool liquidity behavior with different fee structures applied to XYC pairs
 */
contract XYCFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

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

    // Flat fees
    uint32 internal flatFeeInBps = 0.003e9;    // 0.3%
    uint32 internal flatFeeOutBps = 0.005e9;   // 0.5%

    // Progressive fees
    uint32 internal progressiveFeeInBps = 0.1e9;   // 10%
    uint32 internal progressiveFeeOutBps = 0.1e9;  // 10%

    // Protocol fee
    uint32 internal protocolFeeOutBps = 0.002e9;   // 0.2%
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

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public virtual {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

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
        SwapVM _swapVM,
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
        uint256 feeMultiplier = maxFee > 0 ? (1e9 / (1e9 - maxFee)) + 1 : 1;

        uint256 multiplier = imbalanceRatio > feeMultiplier ? imbalanceRatio : feeMultiplier;
        uint256 mintAmount = amount * 10 * (multiplier > 10 ? multiplier : 10);

        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, mintAmount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
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
        Program memory program = ProgramBuilder.init(_opcodes());

        return bytes.concat(
            // Protocol fees BEFORE balances
            (fees.protocolFeeOutBps > 0) ? program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(fees.protocolFeeOutBps, fees.feeRecipient)) : bytes(""),

            // Balances
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balanceA, _balanceB])
                )),

            // Regular fees AFTER balances (0 = disabled)
            (fees.flatFeeInBps > 0) ? program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(fees.flatFeeInBps)) : bytes(""),
            (fees.flatFeeOutBps > 0) ? program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(fees.flatFeeOutBps)) : bytes(""),
            (fees.progressiveFeeInBps > 0) ? program.build(_progressiveFeeInXD,
                FeeArgsBuilder.buildProgressiveFee(fees.progressiveFeeInBps)) : bytes(""),
            (fees.progressiveFeeOutBps > 0) ? program.build(_progressiveFeeOutXD,
                FeeArgsBuilder.buildProgressiveFee(fees.progressiveFeeOutBps)) : bytes(""),

            // Swap instruction
            program.build(_xycSwapXD)
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
            progressiveFeeInBps: 0,
            progressiveFeeOutBps: 0,
            protocolFeeOutBps: 0,
            feeRecipient: feeRecipient
        });
    }

    // ====== XYC Tests ======

    function test_XYC() public {
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
     * Test XYC with progressive fee on input
     */
    function test_XYCProgressiveFeeIn() public {
        FeeConfig memory fees = _feeConfig();
        fees.progressiveFeeInBps = progressiveFeeInBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
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
     * Test  + XYC with progressive fee on output
     */
    function test_XYCProgressiveFeeOut() public {
        FeeConfig memory fees = _feeConfig();
        fees.progressiveFeeOutBps = progressiveFeeOutBps;
        bytes memory bytecode = _buildProgram(balanceA, balanceB, fees);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
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
     * Test  + XYC with protocol fee
     */
    function test_XYCProtocolFee() public virtual {
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

    // Helper functions
    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
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
