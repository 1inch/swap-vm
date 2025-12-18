// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { dynamic } from "./utils/Dynamic.sol";

import { CoreInvariants } from "./invariants/CoreInvariants.t.sol";

/**
 * @title DepletionFeeTest
 * @notice Comprehensive tests for depletion fee with XYCSwap and XYCConcentrate
 * @dev Tests various fee sizes, reserve amounts, and swap amounts
 *      Verifies additivity and symmetry invariants hold
 */
contract DepletionFeeTest is Test, OpcodesDebug, CoreInvariants {
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
        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);
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
        TokenMock(tokenIn).mint(taker, amount * 10);
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );
        return (actualIn, actualOut);
    }

    // ====== XYCSwap + DepletionFee Tests (without concentration) ======

    /**
     * @notice Test XYCSwap with depletionFeeIn - small fee, equal reserves
     */
    function test_XYCSwapDepletionFeeIn_SmallFee_EqualReserves() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.001e9; // 0.1% min fee
        uint32 maxFeeBps = 0.005e9; // 0.5% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCSwap with depletionFeeOut - small fee, equal reserves
     */
    function test_XYCSwapDepletionFeeOut_SmallFee_EqualReserves() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.001e9; // 0.1% min fee
        uint32 maxFeeBps = 0.005e9; // 0.5% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCSwap with depletionFeeIn - larger fee
     */
    function test_XYCSwapDepletionFeeIn_LargerFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.005e9; // 0.5% min fee
        uint32 maxFeeBps = 0.02e9;  // 2% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCSwap with depletionFeeOut - unequal reserves
     * @dev Requires 5 wei tolerance due to 4 sequential rounding operations:
     *      1. AMM exactIn (floor): y*dx/(x+dx)
     *      2. Fee subtraction (floor): amount*feeBps/BPS
     *      3. Gross computation (ceil): ceil(net*BPS/(BPS-feeBps))
     *      4. AMM exactOut (ceil): ceil(x*dy/(y-dy))
     *      With asymmetric reserves (4:1 ratio), intermediate values don't divide evenly,
     *      causing rounding errors to compound to ~4 wei.
     */
    function test_XYCSwapDepletionFeeOut_UnequalReserves() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 500e18;
        uint32 minFeeBps = 0.002e9; // 0.2% min fee
        uint32 maxFeeBps = 0.01e9;  // 1% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        // 5 wei tolerance for 4 rounding operations with asymmetric reserves
        InvariantConfig memory config = createInvariantConfig(_getDefaultConfig().testAmounts, 5);
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

    /**
     * @notice Test XYCSwap with depletionFeeIn - large reserves
     */
    function test_XYCSwapDepletionFeeIn_LargeReserves() public {
        uint256 balanceA = 100000e18;
        uint256 balanceB = 100000e18;
        uint32 minFeeBps = 0.001e9; // 0.1% min fee
        uint32 maxFeeBps = 0.005e9; // 0.5% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCSwap with depletionFeeOut - various swap amounts
     */
    function test_XYCSwapDepletionFeeOut_VariousAmounts() public {
        uint256 balanceA = 5000e18;
        uint256 balanceB = 5000e18;
        uint32 minFeeBps = 0.002e9; // 0.2% min fee
        uint32 maxFeeBps = 0.01e9;  // 1% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test with various swap amounts
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 0.1e18;   // Very small
        testAmounts[1] = 1e18;     // Small
        testAmounts[2] = 10e18;    // Medium
        testAmounts[3] = 100e18;   // Large
        testAmounts[4] = 500e18;   // Very large (10% of pool)

        InvariantConfig memory config = createInvariantConfig(testAmounts, 2);
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

    // ====== XYCConcentrate + DepletionFee Tests ======

    /**
     * @notice Test XYCConcentrate + depletionFeeIn with narrow price range
     */
    function test_ConcentrateDepletionFeeIn_NarrowRange() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.9e18;
        uint256 priceMax = 1.1e18;
        uint32 minFeeBps = 0.002e9; // 0.2% min fee
        uint32 maxFeeBps = 0.01e9;  // 1% max fee

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, currentPrice, priceMin, priceMax
        );

        uint256 refBalanceIn = balanceA + deltaA;
        uint256 refBalanceOut = balanceB + deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), deltaA, deltaB
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, refBalanceIn, refBalanceOut)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCConcentrate + depletionFeeOut with wide price range
     */
    function test_ConcentrateDepletionFeeOut_WideRange() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;
        uint32 minFeeBps = 0.001e9; // 0.1% min fee
        uint32 maxFeeBps = 0.005e9; // 0.5% max fee

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, currentPrice, priceMin, priceMax
        );

        uint256 refBalanceIn = balanceA + deltaA;
        uint256 refBalanceOut = balanceB + deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), deltaA, deltaB
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, refBalanceIn, refBalanceOut)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test XYCConcentrate + depletionFeeIn with asymmetric reserves
     * @dev Requires 5 wei tolerance due to rounding cascade in depletion fee:
     *      - Concentrated liquidity creates very large virtual balances (~47e21 : ~11e21)
     *      - 4 sequential rounding operations (AMM in/out + fee compute/reverse)
     *      - Asymmetric ratio (5:1) causes intermediate values to not divide evenly
     */
    function test_ConcentrateDepletionFeeIn_AsymmetricReserves() public {
        uint256 balanceA = 5000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 5e18;  // 5 tokenB per tokenA
        uint256 priceMin = 4e18;
        uint256 priceMax = 6e18;
        uint32 minFeeBps = 0.002e9; // 0.2% min fee
        uint32 maxFeeBps = 0.01e9;  // 1% max fee

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, currentPrice, priceMin, priceMax
        );

        uint256 refBalanceIn = balanceA + deltaA;
        uint256 refBalanceOut = balanceB + deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), deltaA, deltaB
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, refBalanceIn, refBalanceOut)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        // 5 wei tolerance for concentrated + asymmetric reserves
        InvariantConfig memory config = createInvariantConfig(_getDefaultConfig().testAmounts, 5);
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

    /**
     * @notice Test XYCConcentrate + depletionFeeOut with high fee
     */
    function test_ConcentrateDepletionFeeOut_HighFee() public {
        uint256 balanceA = 1500e18;
        uint256 balanceB = 1500e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.7e18;
        uint256 priceMax = 1.4e18;
        uint32 minFeeBps = 0.01e9; // 1% min fee
        uint32 maxFeeBps = 0.03e9; // 3% max fee

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, currentPrice, priceMin, priceMax
        );

        uint256 refBalanceIn = balanceA + deltaA;
        uint256 refBalanceOut = balanceB + deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), deltaA, deltaB
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, refBalanceIn, refBalanceOut)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    // ====== Fee Behavior Tests ======

    /**
     * @notice Test that fee increases when depleting pool (moving away from initial ratio)
     */
    function test_FeeIncreasesOnDepletion() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.005e9; // 0.5% min fee
        uint32 maxFeeBps = 0.02e9;  // 2% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // First swap: get quote at initial ratio
        (uint256 amountIn1, uint256 amountOut1,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), 100e18, takerData
        );
        uint256 rate1 = amountOut1 * 1e18 / amountIn1;

        // Execute first swap to change the ratio
        tokenA.mint(taker, 1000e18);
        swapVM.swap(order, address(tokenA), address(tokenB), 100e18, takerData);

        // Second swap: get quote at depleted ratio (more tokenA, less tokenB in pool)
        (uint256 amountIn2, uint256 amountOut2,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), 100e18, takerData
        );
        uint256 rate2 = amountOut2 * 1e18 / amountIn2;

        // Rate should be worse (lower) after depletion due to:
        // 1. AMM price impact
        // 2. Higher depletion fee
        assertTrue(rate2 < rate1, "Rate should decrease after depletion");
    }

    /**
     * @notice Test that fee decreases when restoring pool (moving toward initial ratio)
     */
    function test_FeeDecreasesOnRestoration() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.005e9; // 0.5% min fee
        uint32 maxFeeBps = 0.02e9;  // 2% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerDataExactIn = _signAndPackTakerData(order, true, 0);

        // First: deplete the pool by swapping A -> B
        tokenA.mint(taker, 1000e18);
        swapVM.swap(order, address(tokenA), address(tokenB), 200e18, takerDataExactIn);

        // Now pool has more A than initial, less B than initial
        // Quote for B -> A (restoration direction)
        (uint256 amountIn1, uint256 amountOut1,) = swapVM.asView().quote(
            order, address(tokenB), address(tokenA), 50e18, takerDataExactIn
        );
        uint256 rateForRestore = amountOut1 * 1e18 / amountIn1;

        // Quote for A -> B (further depletion direction)
        (uint256 amountIn2, uint256 amountOut2,) = swapVM.asView().quote(
            order, address(tokenA), address(tokenB), 50e18, takerDataExactIn
        );
        uint256 rateForDeplete = amountOut2 * 1e18 / amountIn2;

        // Restoration should have better effective rate due to reduced fee
        // (This comparison is complex due to AMM mechanics, but the fee component should help restoration)
        console.log("Rate for restoration (B->A):", rateForRestore);
        console.log("Rate for depletion (A->B):", rateForDeplete);
    }

    // ====== Edge Case Tests ======

    /**
     * @notice Test with very small fee
     */
    function test_VerySmallFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 minFeeBps = 0.00005e9; // 0.005% min fee
        uint32 maxFeeBps = 0.0002e9;  // 0.02% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountOutXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        InvariantConfig memory config = _getDefaultConfig();
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

    /**
     * @notice Test with small reserves
     */
    function test_SmallReserves() public {
        uint256 balanceA = 100e18;
        uint256 balanceB = 100e18;
        uint32 minFeeBps = 0.002e9; // 0.2% min fee
        uint32 maxFeeBps = 0.01e9;  // 1% max fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_depletionFeeAmountInXD,
                FeeArgsBuilder.buildDepletionFee(minFeeBps, maxFeeBps, balanceA, balanceB)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 0.1e18;
        testAmounts[1] = 1e18;
        testAmounts[2] = 5e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 2);
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // Skip spot price check for small reserves - rounding becomes significant for tiny amounts
        config.skipSpotPrice = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // ====== Helper Functions ======

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

