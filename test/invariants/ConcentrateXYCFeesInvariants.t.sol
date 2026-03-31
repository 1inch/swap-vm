// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title ConcentrateXYCFeesInvariants
 * @notice Tests invariants for XYCConcentrate + XYCSwap with fee configurations
 * @dev Tests concentrated liquidity AMM behavior with different fee structures
 */
contract ConcentrateXYCFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
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
    uint32 internal flatFeeInBps = 0.003e9;    // 0.3%

    // Protocol fee
    uint32 internal protocolFeeOutBps = 0.002e9;   // 0.2%
    address internal feeRecipient = address(0xFEE);

    // Test amounts for invariants
    uint256[] internal testAmounts;

    // Test amounts for exactOut (if empty, uses testAmounts)
    uint256[] internal testAmountsExactOut;

    // Symmetry tolerance (default 2 wei)
    uint256 internal symmetryTolerance = 2;

    // Additivity tolerance (default 1 for concentrate due to L recalculation)
    uint256 internal additivityTolerance = 1;

    // Rounding tolerance in bps (default 100 = 1%)
    uint256 internal roundingToleranceBps = 100;

    // Skip flags for edge cases
    bool internal skipMonotonicity = false;
    bool internal skipSpotPrice = false;

    // Monotonicity tolerance in bps (default 0, strict)
    uint256 internal monotonicityToleranceBps = 0;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public virtual {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

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
     * @dev Uses XYCConcentrateArgsBuilder.computeLiquidityFromAmounts
     */
    function _computeInitialBalances() internal {
        uint256 sqrtPspot = 1e18; // Market spot price = 1.0
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
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
        SwapVM _swapVM,
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
            tokenIn,
            tokenOut,
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
        uint32 _flatFeeInBps,
        uint32 _protocolFeeOutBps
    ) internal view returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());

        return bytes.concat(
            // Protocol fees BEFORE balances
            (_protocolFeeOutBps > 0) ? program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(_protocolFeeOutBps, feeRecipient)) : bytes(""),

            // Balances
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balanceA, _balanceB])
                )),

            // Flat fee BEFORE concentrate (concentrate is terminal)
            (_flatFeeInBps > 0) ? program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(_flatFeeInBps)) : bytes(""),

            // Concentrate instruction (terminal: computes virtual reserves + swap)
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(_sqrtPriceMin, _sqrtPriceMax))
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

    // ====== Concentrate Tests ======

    /**
     * @notice Test concentrate without fees
     */
    function test_ConcentrateXYC() public {
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
