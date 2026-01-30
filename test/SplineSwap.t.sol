// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";
import { MockTaker } from "./mocks/MockTaker.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { AquaOpcodesDebug } from "../src/opcodes/AquaOpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls } from "../src/instructions/Controls.sol";
import { SplineSwap, SplineSwapArgsBuilder } from "../src/instructions/SplineSwap.sol";
import { SplineSwapMath } from "../src/libs/SplineSwapMath.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract SplineSwapTest is Test, AquaOpcodesDebug {
    using ProgramBuilder for Program;

    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_PRICE = 1e18; // 1:1 price
    uint256 constant INITIAL_BALANCE = 100000e18;

    Aqua public immutable aqua = new Aqua();

    AquaSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    MockTaker public taker;

    address public maker;
    uint256 public makerPrivateKey;

    constructor() AquaOpcodesDebug(address(aqua)) {}

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new AquaSwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKNA");
        tokenB = new TokenMock("Token B", "TKNB");

        taker = new MockTaker(aqua, swapVM, address(this));
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function takerData(address takerAddress, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddress,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function buildSplineSwapProgram(
        bytes4 densitySelector,
        bytes4 priceFormulaSelector
    ) internal view returns (bytes memory) {
        return buildSplineSwapProgramAsymmetric(
            densitySelector,
            densitySelector,
            priceFormulaSelector,
            priceFormulaSelector
        );
    }

    function buildSplineSwapProgramAsymmetric(
        bytes4 sellDensitySelector,
        bytes4 buyDensitySelector,
        bytes4 sellPriceFormulaSelector,
        bytes4 buyPriceFormulaSelector
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(SplineSwap._splineSwapGrowPriceRange2D,
                SplineSwapArgsBuilder.build(SplineSwapArgsBuilder.Args({
                    initialPrice: INITIAL_PRICE,
                    token0ToSell: INITIAL_BALANCE,
                    token0ToBuy: INITIAL_BALANCE,
                    sellRangeBps: 2500, // 25% range
                    buyRangeBps: 2500,
                    sellAskBps: 30, // 0.3% spread
                    sellBidBps: 30,
                    buyAskBps: 30,
                    buyBidBps: 30,
                    sellDensitySelector: sellDensitySelector,
                    buyDensitySelector: buyDensitySelector,
                    sellPriceFormulaSelector: sellPriceFormulaSelector,
                    buyPriceFormulaSelector: buyPriceFormulaSelector
                }))),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function createStrategy(bytes memory programBytes) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
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
            program: programBytes
        }));
    }

    function shipStrategy(ISwapVM.Order memory order) internal returns (bytes32) {
        vm.prank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(aqua), type(uint256).max);

        tokenA.mint(maker, INITIAL_BALANCE);
        tokenB.mint(maker, INITIAL_BALANCE);

        bytes memory strategy = abi.encode(order);

        vm.prank(maker);
        return aqua.ship(
            address(swapVM),
            strategy,
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
    }

    function executeSwap(
        ISwapVM.Order memory order,
        uint256 swapAmount,
        bool isExactIn,
        bool zeroForOne
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        // Mint tokens to taker
        if (zeroForOne) {
            tokenA.mint(address(taker), swapAmount * 2);
        } else {
            tokenB.mint(address(taker), swapAmount * 2);
        }

        bytes memory sigAndTakerData = abi.encodePacked(takerData(address(taker), isExactIn));

        address tokenIn = zeroForOne ? address(tokenA) : address(tokenB);
        address tokenOut = zeroForOne ? address(tokenB) : address(tokenA);

        (amountIn, amountOut) = taker.swap(
            order,
            tokenIn,
            tokenOut,
            swapAmount,
            sigAndTakerData
        );
    }

    // ========================================
    // DENSITY STRATEGY TESTS
    // ========================================

    function test_Density_Uniform() public {
        console.log("\n=== Testing UNIFORM Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_Quadratic() public {
        console.log("\n=== Testing QUADRATIC Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.QUADRATIC_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_Stable() public {
        console.log("\n=== Testing STABLE Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.STABLE_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_ExponentialDecay() public {
        console.log("\n=== Testing EXPONENTIAL_DECAY Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.EXP_DECAY_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_ExponentialGrowth() public {
        console.log("\n=== Testing EXPONENTIAL_GROWTH Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.EXP_GROWTH_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_Concentrated() public {
        console.log("\n=== Testing CONCENTRATED Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.CONCENTRATED_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_SquareRoot() public {
        console.log("\n=== Testing SQUARE_ROOT Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.SQRT_DENSITY_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_QuarticDecay() public {
        console.log("\n=== Testing QUARTIC_DECAY Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.QUARTIC_DECAY_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_QuarticGrowth() public {
        console.log("\n=== Testing QUARTIC_GROWTH Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.QUARTIC_GROWTH_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_AntiConcentrated() public {
        console.log("\n=== Testing ANTI_CONCENTRATED Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.ANTI_CONCENTRATED_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_Plateau() public {
        console.log("\n=== Testing PLATEAU Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.PLATEAU_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Density_Sigmoid() public {
        console.log("\n=== Testing SIGMOID Density ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.SIGMOID_DENSITY_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    // ========================================
    // PRICE FORMULA TESTS
    // ========================================

    function test_PriceFormula_Spline() public {
        console.log("\n=== Testing SPLINE Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_ConstantProduct() public {
        console.log("\n=== Testing CONSTANT_PRODUCT Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.CONSTANT_PRODUCT_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Exponential() public {
        console.log("\n=== Testing EXPONENTIAL Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.EXPONENTIAL_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_StableSwap() public {
        console.log("\n=== Testing STABLESWAP Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.STABLESWAP_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Sqrt() public {
        console.log("\n=== Testing SQRT Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.SQRT_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Cubic() public {
        console.log("\n=== Testing CUBIC Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.CUBIC_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Log() public {
        console.log("\n=== Testing LOG Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.LOG_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Sigmoid() public {
        console.log("\n=== Testing SIGMOID Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.SIGMOID_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceFormula_Hyperbolic() public {
        console.log("\n=== Testing HYPERBOLIC Price Formula ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.HYPERBOLIC_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    // ========================================
    // EXACT OUT MODE TEST
    // ========================================

    function test_ExactOut_Uniform() public {
        console.log("\n=== Testing ExactOut Mode ===");

        bytes memory program = buildSplineSwapProgram(
            SplineSwapMath.UNIFORM_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        uint256 desiredOutput = 900e18;
        (uint256 amountIn, uint256 amountOut) = executeSwap(order, desiredOutput, false, true);

        console.log("  Desired output: %s tokenB", desiredOutput / 1e18);
        console.log("  Paid: %s tokenA", amountIn / 1e18);
        console.log("  Received: %s tokenB", amountOut / 1e18);

        assertEq(amountOut, desiredOutput, "Should receive exact output");
        assertGt(amountIn, desiredOutput, "Should pay more due to slippage");
    }

    // ========================================
    // ASYMMETRIC CONFIGURATION TEST
    // ========================================

    function test_AsymmetricConfiguration() public {
        console.log("\n=== Testing Asymmetric Configuration ===");
        console.log("  Sell side: ExponentialDecay density + Spline price");
        console.log("  Buy side: ExponentialGrowth density + ConstantProduct price");

        bytes memory program = buildSplineSwapProgramAsymmetric(
            SplineSwapMath.EXP_DECAY_SELECTOR,
            SplineSwapMath.EXP_GROWTH_SELECTOR,
            SplineSwapMath.SPLINE_PRICE_SELECTOR,
            SplineSwapMath.CONSTANT_PRODUCT_SELECTOR
        );
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }
}
