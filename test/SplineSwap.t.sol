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

    function buildSplineSwapProgram() internal view returns (bytes memory) {
        return buildSplineSwapProgramWithParams(INITIAL_PRICE, 2500, 30);
    }

    function buildSplineSwapProgramWithParams(
        uint256 price,
        uint16 rangeBps,
        uint16 spreadBps
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(SplineSwap._splineSwapGrowPriceRange2D,
                SplineSwapArgsBuilder.build(SplineSwapArgsBuilder.Args({
                    initialPrice: price,
                    token0ToSell: INITIAL_BALANCE,
                    token0ToBuy: INITIAL_BALANCE,
                    sellRangeBps: rangeBps,
                    buyRangeBps: rangeBps,
                    sellAskBps: spreadBps,
                    sellBidBps: spreadBps,
                    buyAskBps: spreadBps,
                    buyBidBps: spreadBps
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
    // BASIC TESTS
    // ========================================

    function test_BasicSwap_ExactIn() public {
        console.log("\n=== Testing Basic ExactIn Swap ===");

        bytes memory program = buildSplineSwapProgram();
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_BasicSwap_ExactOut() public {
        console.log("\n=== Testing Basic ExactOut Swap ===");

        bytes memory program = buildSplineSwapProgram();
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
    // PRICE RANGE TESTS
    // ========================================

    function test_PriceRange_SmallRange() public {
        console.log("\n=== Testing Small Price Range (5%) ===");

        bytes memory program = buildSplineSwapProgramWithParams(INITIAL_PRICE, 500, 30);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 10000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_PriceRange_LargeRange() public {
        console.log("\n=== Testing Large Price Range (50%) ===");

        bytes memory program = buildSplineSwapProgramWithParams(INITIAL_PRICE, 5000, 30);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 10000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    // ========================================
    // SPREAD TESTS
    // ========================================

    function test_Spread_Zero() public {
        console.log("\n=== Testing Zero Spread ===");

        bytes memory program = buildSplineSwapProgramWithParams(INITIAL_PRICE, 2500, 0);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Spread_Large() public {
        console.log("\n=== Testing Large Spread (1%) ===");

        bytes memory program = buildSplineSwapProgramWithParams(INITIAL_PRICE, 2500, 100);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    // ========================================
    // PRICE TESTS
    // ========================================

    function test_Price_HighPrice() public {
        console.log("\n=== Testing High Initial Price (2000:1) ===");

        bytes memory program = buildSplineSwapProgramWithParams(2000e18, 2500, 30);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 2000000e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    function test_Price_LowPrice() public {
        console.log("\n=== Testing Low Initial Price (1:2000) ===");

        bytes memory program = buildSplineSwapProgramWithParams(1e18 / 2000, 2500, 30);
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = executeSwap(order, 1e18, true, true);

        console.log("  Swap %s tokenA", amountIn / 1e18);
        console.log("  Received %s tokenB", amountOut / 1e18);

        assertGt(amountOut, 0, "Should receive tokens");
    }

    // ========================================
    // MULTIPLE SWAPS TEST
    // ========================================

    function test_MultipleSwaps() public {
        console.log("\n=== Testing Multiple Swaps (Price Movement) ===");

        bytes memory program = buildSplineSwapProgram();
        ISwapVM.Order memory order = createStrategy(program);
        shipStrategy(order);

        // First swap
        (uint256 amountIn1, uint256 amountOut1) = executeSwap(order, 10000e18, true, true);
        console.log("  Swap 1: %s tokenA -> %s tokenB", amountIn1 / 1e18, amountOut1 / 1e18);

        // Second swap (price should be higher now)
        (uint256 amountIn2, uint256 amountOut2) = executeSwap(order, 10000e18, true, true);
        console.log("  Swap 2: %s tokenA -> %s tokenB", amountIn2 / 1e18, amountOut2 / 1e18);

        // Third swap
        (uint256 amountIn3, uint256 amountOut3) = executeSwap(order, 10000e18, true, true);
        console.log("  Swap 3: %s tokenA -> %s tokenB", amountIn3 / 1e18, amountOut3 / 1e18);

        // Due to price increase, we should get less tokens for the same input
        assertGt(amountOut1, amountOut2, "Second swap should give less due to price increase");
        assertGt(amountOut2, amountOut3, "Third swap should give less due to price increase");
    }
}
