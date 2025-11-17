// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { Invalidators, InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

// Simple mock token for testing
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SwapVMTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router with Invalidators
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_LimitSwapWithTokenOutInvalidator() public {
        // === Setup ===
        // Maker offers to sell 100 TokenA for 200 TokenB (rate: 2 TokenB per 1 TokenA)
        uint256 makerBalanceA = 100e18;
        uint256 makerBalanceB = 200e18;

        // === Build Program ===
        // Create limit order with TokenOut invalidator to track partial fills
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([makerBalanceA, makerBalanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA))),
            p.build(Invalidators._invalidateTokenOut1D),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(0x1235)) // Unique salt to ensure different order hash
        );

        // === Create Order ===
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0), // (0 = maker)
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

        // === Sign Order ===
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // === Execute First Partial Fill ===
        // Taker buys 25 TokenA for 50 TokenB
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)), // min TokenA to receive
            to: address(0), // 0 = taker
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

        uint256 takerBalanceABefore = tokenA.balanceOf(taker);
        uint256 takerBalanceBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn1, uint256 amountOut1,) = swapVM.swap(
            order,
            address(tokenB), // tokenIn
            address(tokenA), // tokenOut
            50e18,           // amount of tokenB to spend
            takerData
        );

        // Verify first fill
        assertEq(amountIn1, 50e18, "First fill: incorrect amountIn");
        assertEq(amountOut1, 25e18, "First fill: incorrect amountOut");
        assertEq(tokenA.balanceOf(taker) - takerBalanceABefore, 25e18, "First fill: incorrect TokenA received");
        assertEq(takerBalanceBBefore - tokenB.balanceOf(taker), 50e18, "First fill: incorrect TokenB spent");

        // === Execute Second Partial Fill ===
        // Taker buys another 25 TokenA for 50 TokenB
        takerBalanceABefore = tokenA.balanceOf(taker);
        takerBalanceBBefore = tokenB.balanceOf(taker);

        vm.prank(taker);
        (uint256 amountIn2, uint256 amountOut2,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );

        // Verify second fill
        assertEq(amountIn2, 50e18, "Second fill: incorrect amountIn");
        assertEq(amountOut2, 25e18, "Second fill: incorrect amountOut");
        assertEq(tokenA.balanceOf(taker) - takerBalanceABefore, 25e18, "Second fill: incorrect TokenA received");
        assertEq(takerBalanceBBefore - tokenB.balanceOf(taker), 50e18, "Second fill: incorrect TokenB spent");

        // === Verify Invalidator State ===
        // At this point, 50 TokenA has been sold (tracked by invalidator)
        // Total balances: 50 TokenA and 100 TokenB remaining

        // === Execute Third Partial Fill ===
        // This should work as we haven't exceeded the total balance
        vm.prank(taker);
        (uint256 amountIn3, uint256 amountOut3,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            80e18, // Try to buy 40 TokenA for 80 TokenB
            takerData
        );

        assertEq(amountIn3, 80e18, "Third fill: incorrect amountIn");
        assertEq(amountOut3, 40e18, "Third fill: incorrect amountOut");

        // === Attempt to Overfill ===
        // Try to buy more than remaining (only 10 TokenA left)
        bytes memory overFillTakerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(30e18)), //  try to get 30 TokenA, but only 10 left
            to: address(0), // 0 = taker
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

        vm.prank(taker);
        vm.expectRevert(); // Should revert due to invalidator preventing overfill
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            60e18, // Try to spend 60 TokenB for 30 TokenA (but only 10 left)
            overFillTakerData
        );

        // === Final Fill ===
        // Fill the remaining 10 TokenA for 20 TokenB
        bytes memory finalTakerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(10e18)), //  try to get 30 TokenA, but only 10 left
            to: address(0), // 0 = taker
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

        vm.prank(taker);
        (uint256 amountIn4, uint256 amountOut4,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            20e18, // Spend exactly 20 TokenB for remaining 10 TokenA
            finalTakerData
        );

        assertEq(amountIn4, 20e18, "Final fill: incorrect amountIn");
        assertEq(amountOut4, 10e18, "Final fill: incorrect amountOut");

        // === Verify Order Fully Filled ===
        // Total filled: 100 TokenA for 200 TokenB (as intended)
        assertEq(tokenA.balanceOf(taker), 100e18, "Total TokenA received incorrect");
        assertEq(tokenB.balanceOf(maker), 200e18, "Total TokenB received by maker incorrect");

        // Try to fill again - should fail as order is fully filled
        vm.prank(taker);
        vm.expectRevert(); // Should revert - order fully filled
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            1e18, // Try any amount
            takerData
        );
    }

    function test_LimitSwapWithoutInvalidator_ReusableOrder() public {
        // === Build Program WITHOUT Invalidator ===
        // This demonstrates that without invalidator, order can be reused
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([uint256(100e18), 200e18]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
            // NO INVALIDATOR - order can be filled multiple times!
        );

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)),
            to: address(0),
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

        // First fill - works
        vm.prank(taker);
        (, uint256 amountOut1,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );
        assertEq(amountOut1, 25e18, "Without invalidator: first fill works");

        // Second fill - also works! (This is the desired behavior for reusable orders)
        vm.prank(taker);
        (, uint256 amountOut2,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );
        assertEq(amountOut2, 25e18, "Without invalidator: order can be reused!");

        // This demonstrates the difference - invalidators provide fill tracking
    }
}
