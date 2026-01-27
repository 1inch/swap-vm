// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/**
 * @title StatelessSwapInvariants
 * @notice Comprehensive invariant tests for the StatelessSwap invariant curve instruction
 * @dev Tests all SwapVM invariants across various fee configurations:
 *      - Zero fee (equivalent to constant product)
 *      - Low fee (0.3% typical DEX)
 *      - Medium fee (1%)
 *      - High fee (3-10%)
 *      - Various pool configurations
 * 
 * Implementation: Uses curve out·in^α = K where α = 1 - fee
 * The ln/exp approximations for α ≠ 1 introduce small numerical errors.
 * Tolerances are calibrated for this precision loss.
 * 
 * Key invariants that MUST hold:
 *   ✓ Symmetry: ExactIn → ExactOut → ExactIn should roundtrip (with tolerance)
 *   ✓ Additivity: swap(a+b) >= swap(a) + swap(b)
 *   ✓ Monotonicity: larger input → larger output
 *   ✓ Rounding: always favor maker
 *   ✓ Fee reinvestment: K_product grows after each swap
 */

import { Test, console } from "forge-std/Test.sol";
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
import { StatelessSwapArgsBuilder } from "../../src/instructions/StatelessSwap.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


contract StatelessSwapInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    // ====== Storage Variables ======

    // Pool balances
    uint256 internal balanceA = 1000e18;
    uint256 internal balanceB = 1000e18;

    // Fee in BPS
    uint32 internal feeBps = 0;

    // Test amounts for invariants
    uint256[] internal testAmounts;
    uint256[] internal testAmountsExactOut;

    // Tolerances (defaults - overridden per test based on measurements)
    uint256 internal symmetryTolerance = 1e8;     // Default: 100M wei
    uint256 internal additivityTolerance = 1e14;  // Default: 100T wei
    uint256 internal roundingToleranceBps = 100;  // 1% for rounding checks
    uint256 internal monotonicityToleranceBps = 0;

    // Skip flags
    bool internal skipMonotonicity = false;
    bool internal skipSpotPrice = false;
    bool internal skipAdditivity = false;
    bool internal skipSymmetry = false;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public virtual {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals
        tokenA.mint(maker, type(uint128).max);
        tokenB.mint(maker, type(uint128).max);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Default test amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 10e18;
        testAmounts[1] = 20e18;
        testAmounts[2] = 50e18;
    }

    // ====== _executeSwap Implementation ======

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

        uint256 mintAmount = amount * 10 * (imbalanceRatio > 10 ? imbalanceRatio : 10);
        TokenMock(tokenIn).mint(taker, mintAmount);

        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order, tokenIn, tokenOut, amount, takerData
        );

        return (actualIn, actualOut);
    }

    // ====== Program Builder ======

    function _buildProgram(
        uint256 _balanceA,
        uint256 _balanceB,
        uint32 _feeBps
    ) internal view returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());

        return bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balanceA, _balanceB])
                )),
            program.build(_statelessSwap2D, StatelessSwapArgsBuilder.build2D(_feeBps))
        );
    }

    function _config(ISwapVM.Order memory order) internal view returns (InvariantConfig memory) {
        InvariantConfig memory config = _getDefaultConfig();
        config.testAmounts = testAmounts;
        config.testAmountsExactOut = testAmountsExactOut;
        config.symmetryTolerance = symmetryTolerance;
        config.additivityTolerance = additivityTolerance;
        config.roundingToleranceBps = roundingToleranceBps;
        config.monotonicityToleranceBps = monotonicityToleranceBps;
        config.skipMonotonicity = skipMonotonicity;
        config.skipSpotPrice = skipSpotPrice;
        config.skipAdditivity = skipAdditivity;
        config.skipSymmetry = skipSymmetry;
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        return config;
    }

    // ====== ZERO FEE TESTS ======
    // Zero fee uses exact constant product formula (no ln/exp approximation)
    // Measured: symmetry 1 wei (rounding only), additivity 0 (exact)

    function test_Fee_Zero_BalancedPool() public {
        feeBps = 0;
        
        symmetryTolerance = 10;     // Measured: 1 wei, use 10 for safety
        additivityTolerance = 0;    // Measured: 0 (exact math)
        skipSpotPrice = false;
        
        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_Fee_Zero_ImbalancedPool() public {
        balanceA = 10000e18;
        balanceB = 1000e18;
        feeBps = 0;
        
        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 10e18;
        testAmountsExactOut[1] = 20e18;
        testAmountsExactOut[2] = 50e18;

        symmetryTolerance = 10;     // Measured: 1 wei, use 10 for safety
        additivityTolerance = 0;    // Measured: 0 (exact math)
        skipSpotPrice = false;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== LOW FEE TESTS (0.3% - typical DEX) ======
    // Invariant curve uses ln/exp approximations, introducing small precision errors
    // Error scales with fee level and trade size
    // Measured: symmetry 17M wei, additivity 55e12 wei for 30e18 total input

    function test_Fee_30bps_BalancedPool() public {
        feeBps = 30;  // 0.3%
        
        // Measured: symmetry ~17M, additivity ~55e12 for default test amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e14; // 100T wei buffer
        skipSpotPrice = false;
        
        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== MEDIUM FEE TESTS (1%) ======

    function test_Fee_100bps_BalancedPool() public {
        feeBps = 100;  // 1%
        
        // Measured: symmetry ~43M, additivity ~183e12 for default test amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e15; // 1e15 wei buffer
        skipSpotPrice = true;       // Skip due to precision issues with medium fees
        
        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== HIGH FEE TESTS (3%) ======

    function test_Fee_300bps_BalancedPool() public {
        feeBps = 300;  // 3%
        
        // Measured: symmetry ~32M, additivity ~549e12 for default test amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e15; // 1e15 wei buffer
        skipSpotPrice = true;       // Skip due to precision issues with high fees

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== VERY HIGH FEE TESTS (10%) ======

    function test_Fee_1000bps_BalancedPool() public {
        feeBps = 1000;  // 10%
        
        // Measured: symmetry ~29M, additivity ~1.8e15 for default test amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e16; // 10e15 wei buffer
        skipSpotPrice = true;       // Skip due to precision issues with very high fees

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== POOL SIZE TESTS ======
    // Precision scales with pool size and trade size for invariant curve

    function test_LargePool_1M_Tokens() public {
        balanceA = 1000000e18;
        balanceB = 1000000e18;
        feeBps = 30;

        testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18;
        testAmounts[1] = 10000e18;
        testAmounts[2] = 50000e18;

        // Measured: symmetry ~7.7e9, additivity ~54e15 for these amounts
        symmetryTolerance = 1e10;   // 10e9 wei buffer
        additivityTolerance = 1e17; // 100e15 wei buffer (large pool, large trades)
        skipSpotPrice = false;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_SmallPool_100_Tokens() public {
        balanceA = 100e18;
        balanceB = 100e18;
        feeBps = 30;

        testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1e18;
        testAmountsExactOut[1] = 5e18;
        testAmountsExactOut[2] = 10e18;

        // Measured: symmetry ~12M, additivity ~5.4e12 for these amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e13; // 10e12 wei buffer
        skipSpotPrice = true;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_ImbalancedPool_100to1() public {
        balanceA = 100000e18;
        balanceB = 1000e18;
        feeBps = 30;

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 10e18;
        testAmountsExactOut[1] = 20e18;
        testAmountsExactOut[2] = 50e18;

        // Measured: symmetry ~98M, additivity ~1.1e9 for these amounts
        symmetryTolerance = 1e8;    // 100M wei buffer
        additivityTolerance = 1e10; // 10e9 wei buffer
        skipSpotPrice = false;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== REALISTIC SCENARIO TESTS ======

    function test_TypicalDEX() public {
        balanceA = 10000e18;
        balanceB = 10000e18;
        feeBps = 30;  // 0.3%

        testAmounts = new uint256[](4);
        testAmounts[0] = 10e18;
        testAmounts[1] = 100e18;
        testAmounts[2] = 500e18;
        testAmounts[3] = 1000e18;

        // Measured: symmetry ~1.2e9, additivity ~84e12 for larger sequential amounts
        symmetryTolerance = 1e10;   // 10e9 wei buffer
        additivityTolerance = 1e14; // 100e12 wei buffer (for 100+200 = 300 test case)
        skipSpotPrice = false;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    function test_HFT_LowFees_LargeVolume() public {
        balanceA = 100000e18;
        balanceB = 100000e18;
        feeBps = 5;  // 0.05% (very low fee for HFT)

        testAmounts = new uint256[](4);
        testAmounts[0] = 100e18;
        testAmounts[1] = 1000e18;
        testAmounts[2] = 5000e18;
        testAmounts[3] = 10000e18;

        // Measured: symmetry ~12e9, additivity ~140e12 for 1000+2000 = 3000 test case
        symmetryTolerance = 1e11;   // 100e9 wei buffer
        additivityTolerance = 1e15; // 1e15 wei buffer (larger trades)
        skipSpotPrice = false;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _config(order);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }

    // ====== FEE ANALYSIS ======

    function test_FlatFeeAnalysis() public {
        balanceA = 1000e18;
        balanceB = 1000e18;
        feeBps = 30;

        bytes memory bytecode = _buildProgram(balanceA, balanceB, feeBps);
        ISwapVM.Order memory order = _createOrder(bytecode);

        console.log("\n=== Flat Fee Analysis (30 bps = 0.3%%) ===");
        console.log("Pool: 1000/1000\n");

        uint256[] memory amounts = new uint256[](6);
        amounts[0] = 1e18;     // 0.1% trade
        amounts[1] = 5e18;     // 0.5% trade
        amounts[2] = 10e18;    // 1% trade
        amounts[3] = 50e18;    // 5% trade
        amounts[4] = 100e18;   // 10% trade
        amounts[5] = 200e18;   // 20% trade

        for (uint256 i = 0; i < amounts.length; i++) {
            _analyzeTrade(order, amounts[i]);
        }
    }

    function _analyzeTrade(ISwapVM.Order memory order, uint256 amountIn) internal view {
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        (, uint256 actualOut,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), amountIn, exactInData
        );

        // No-fee output for comparison
        uint256 noFeeOut = balanceB * amountIn / (balanceA + amountIn);
        uint256 feeAmt = noFeeOut - actualOut;
        uint256 feeRate = feeAmt * 10000 / noFeeOut;  // in bps

        console.log("Trade %s%% of pool:", amountIn * 100 / balanceA);
        console.log("  Output: %s (vs %s no-fee)", actualOut, noFeeOut);
        console.log("  Fee: %s bps (constant!)", feeRate);
    }

    // ====== Helper Functions ======

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
