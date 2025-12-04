// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib, TakerTraits } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { Invalidators, InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract SwapVMTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        address tokenIn;
        address tokenOut;
        bool useInvalidator;
        uint256 salt;
    }

    struct TakerSetup {
        bool isExactIn;
        uint256 threshold;
        bool isFirstTransferFromTaker;
    }

    struct SwapResult {
        uint256 amountIn;
        uint256 amountOut;
    }

    struct BalanceSnapshot {
        uint256 takerTokenA;
        uint256 takerTokenB;
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router with Invalidators
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([setup.balanceA, setup.balanceB]))),
            p.build(LimitSwap._limitSwap1D,
                LimitSwapArgsBuilder.build(setup.tokenIn, setup.tokenOut)),
            setup.useInvalidator ? p.build(Invalidators._invalidateTokenOut1D) : bytes(""),
            setup.salt != 0 ? p.build(Controls._salt, ControlsArgsBuilder.buildSalt(uint64(setup.salt))) : bytes("")
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(uint256 threshold, bytes memory signature) internal view returns (bytes memory) {
        // Build taker data step by step to avoid stack too deep
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = true;
        args.isFirstTransferFromTaker = true;
        args.threshold = threshold > 0 ? abi.encodePacked(threshold) : bytes("");
        args.signature = signature;

        // All other fields remain default (false/0/empty)
        return TakerTraitsLib.build(args);
    }

    function _executeSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bytes memory takerData
    ) internal returns (SwapResult memory) {
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            amount,
            takerData
        );
        return SwapResult(amountIn, amountOut);
    }

    function _getBalances() internal view returns (BalanceSnapshot memory) {
        return BalanceSnapshot({
            takerTokenA: tokenA.balanceOf(taker),
            takerTokenB: tokenB.balanceOf(taker)
        });
    }

    function _verifySwap(
        SwapResult memory result,
        BalanceSnapshot memory before,
        uint256 expectedIn,
        uint256 expectedOut,
        string memory message
    ) internal view {
        BalanceSnapshot memory afterSwap = _getBalances();

        assertEq(result.amountIn, expectedIn, string(abi.encodePacked(message, ": incorrect amountIn")));
        assertEq(result.amountOut, expectedOut, string(abi.encodePacked(message, ": incorrect amountOut")));
        assertEq(afterSwap.takerTokenA - before.takerTokenA, expectedOut, string(abi.encodePacked(message, ": incorrect TokenA received")));
        assertEq(before.takerTokenB - afterSwap.takerTokenB, expectedIn, string(abi.encodePacked(message, ": incorrect TokenB spent")));
    }


    function test_LimitSwapWithTokenOutInvalidator() public {
        // === Setup ===
        // Maker offers to sell 100 TokenA for 200 TokenB (rate: 2 TokenB per 1 TokenA)
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            useInvalidator: true,
            salt: 0x1235
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature);

        // === Execute First Partial Fill ===
        // Taker buys 25 TokenA for 50 TokenB
        BalanceSnapshot memory before = _getBalances();
        SwapResult memory result = _executeSwap(order, 50e18, takerData);
        _verifySwap(result, before, 50e18, 25e18, "First fill");

        // === Execute Second Partial Fill ===
        // Taker buys another 25 TokenA for 50 TokenB
        before = _getBalances();
        result = _executeSwap(order, 50e18, takerData);
        _verifySwap(result, before, 50e18, 25e18, "Second fill");

        // === Execute Third Partial Fill ===
        // This should work as we haven't exceeded the total balance
        before = _getBalances();
        result = _executeSwap(order, 80e18, takerData);
        _verifySwap(result, before, 80e18, 40e18, "Third fill");

        // === Attempt to Overfill ===
        // Try to buy more than remaining (only 10 TokenA left)
        bytes memory overFillTakerData = _buildTakerData(30e18, signature);
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
        bytes memory finalTakerData = _buildTakerData(10e18, signature);
        before = _getBalances();
        result = _executeSwap(order, 20e18, finalTakerData);
        _verifySwap(result, before, 20e18, 10e18, "Final fill");

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
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            useInvalidator: false,  // NO INVALIDATOR - order can be filled multiple times!
            salt: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Use simplified taker data construction
        bytes memory takerData = _buildTakerData(25e18, signature);

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
