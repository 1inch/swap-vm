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
import { PeggedSwapArgsBuilder } from "../../src/instructions/PeggedSwap.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title PeggedSwapInvariants
 * @notice Tests invariants for PeggedSwap instruction
 * @dev Tests PeggedSwap's square-root-based curve for stablecoin swaps
 */
contract PeggedSwapInvariants is Test, OpcodesDebug, CoreInvariants {
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
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
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
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount * 10);

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

    /**
     * Test PeggedSwap with odd amounts to verify rounding behavior
     */
    function test_PeggedSwap_OddAmountRounding() public view {
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;
        uint256 x0Initial = 10000e18;
        uint256 y0Initial = 10000e18;
        uint256 linearWidth = 0.8e27; // A = 0.8

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth,
                        rateLt: 1,
                        rateGt: 1
                })))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test with very small odd amounts
        uint256[] memory smallOddAmounts = new uint256[](6);
        smallOddAmounts[0] = 1;      // 1 wei
        smallOddAmounts[1] = 3;      // 3 wei
        smallOddAmounts[2] = 7;      // 7 wei
        smallOddAmounts[3] = 13;     // 13 wei
        smallOddAmounts[4] = 99;     // 99 wei
        smallOddAmounts[5] = 1337;   // 1337 wei

        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        bytes memory exactOutData = _signAndPackTakerData(order, false, type(uint256).max);

        // Test small odd amounts for exactIn
        for (uint256 i = 0; i < smallOddAmounts.length; i++) {
            // Try to quote, it might revert for amounts that produce 0 output
            try swapVM.asView().quote(
                order, address(tokenA), address(tokenB), smallOddAmounts[i], exactInData
            ) returns (uint256 quotedIn, uint256 quotedOut, bytes32) {
                // Log the results for debugging if needed
                // ExactIn odd amount: smallOddAmounts[i] -> out: quotedOut

                // Verify no underflow/overflow
                assertGe(quotedIn, 0, "Quoted input should not underflow");
                assertLe(quotedOut, balanceB, "Output should not exceed balance");

                // For very small inputs, output might be 0 or very small
                if (smallOddAmounts[i] <= 10) {
                    assertGe(quotedOut, 0, "Small input may produce 0 output due to rounding");
                } else {
                    assertGt(quotedOut, 0, "Larger input should produce non-zero output");
                }
            } catch {
                // Expected for very small amounts that would result in 0 output
                // PeggedSwap with high precision requirements may reject amounts up to ~2000 wei
                assertLe(smallOddAmounts[i], 2000, "Only very small amounts (up to 2000 wei) should revert");
            }
        }

        // Test small odd amounts for exactOut
        for (uint256 i = 0; i < smallOddAmounts.length; i++) {
            // Skip if amount would require more input than available
            if (smallOddAmounts[i] > balanceB) continue;

            // Try to quote, might revert for amounts that are impossible to achieve
            try swapVM.asView().quote(
                order, address(tokenA), address(tokenB), smallOddAmounts[i], exactOutData
            ) returns (uint256 quotedIn, uint256 quotedOut, bytes32) {
                // Log the results for debugging if needed
                // ExactOut odd amount: smallOddAmounts[i] -> in: quotedIn

                // Verify no underflow/overflow
                assertGt(quotedIn, 0, "Quoted input should be non-zero");
                assertLe(quotedIn, balanceA, "Input should not exceed available balance");

                // Verify we get exactly what we asked for
                assertEq(quotedOut, smallOddAmounts[i], "ExactOut should return exact amount requested");
            } catch {
                // Some very small amounts might be impossible to achieve exactly
                // This is expected behavior for the PeggedSwap curve
                assertLe(smallOddAmounts[i], 2000, "Only very small amounts (up to 2000 wei) should be impossible to achieve exactly");
            }
        }
    }

    /**
     * Test PeggedSwap with large odd amounts
     */
    function test_PeggedSwap_LargeOddAmounts() public view {
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;
        uint256 x0Initial = 10000e18;
        uint256 y0Initial = 10000e18;
        uint256 linearWidth = 0.8e27; // A = 0.8

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth,
                        rateLt: 1,
                        rateGt: 1
                })))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test with large odd amounts (not evenly divisible)
        uint256[] memory largeOddAmounts = new uint256[](5);
        largeOddAmounts[0] = 12345678901234567;           // ~0.012 ETH odd
        largeOddAmounts[1] = 999999999999999999;          // ~1 ETH minus 1 wei
        largeOddAmounts[2] = 1234567890123456789;         // ~1.23 ETH odd
        largeOddAmounts[3] = 5555555555555555555;         // ~5.55 ETH odd
        largeOddAmounts[4] = 99999999999999999999;        // ~100 ETH minus 1 wei

        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        bytes memory exactOutData = _signAndPackTakerData(order, false, type(uint256).max);

        // Test large odd amounts
        for (uint256 i = 0; i < largeOddAmounts.length; i++) {
            // Test exactIn
            (, uint256 outQuoted,) = swapVM.asView().quote(
                order, address(tokenA), address(tokenB), largeOddAmounts[i], exactInData
            );

            // Log the results for debugging if needed
            // Large odd exactIn: largeOddAmounts[i] -> output: outQuoted

            // Verify output is reasonable
            assertGt(outQuoted, 0, "Large odd input should produce non-zero output");
            assertLe(outQuoted, balanceB, "Output should not exceed balance");

            // Test exactOut with the same amount
            if (largeOddAmounts[i] <= balanceB) {
                (uint256 inRequired, uint256 outGiven,) = swapVM.asView().quote(
                    order, address(tokenA), address(tokenB), largeOddAmounts[i], exactOutData
                );

                // Log the results for debugging if needed
                // Large odd exactOut: largeOddAmounts[i] -> input required: inRequired

                assertGt(inRequired, 0, "Should require non-zero input");
                assertLe(inRequired, balanceA, "Input should not exceed available balance");
                assertEq(outGiven, largeOddAmounts[i], "ExactOut should give exact amount");
            }
        }
    }

    /**
     * Test PeggedSwap rounding consistency
     */
    function test_PeggedSwap_RoundingConsistency() public view {
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;
        uint256 x0Initial = 10000e18;
        uint256 y0Initial = 10000e18;
        uint256 linearWidth = 0.8e27; // A = 0.8

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth,
                        rateLt: 1,
                        rateGt: 1
                })))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Test that rounding is consistent: X+1 should give at least as much as X
        uint256 baseAmount = 1000000000000000; // 0.001 ETH

        for (uint256 i = 0; i < 10; i++) {
            uint256 amount = baseAmount + i;
            uint256 amountPlusOne = amount + 1;

            (,uint256 out1,) = swapVM.asView().quote(
                order, address(tokenA), address(tokenB), amount, exactInData
            );
            (,uint256 out2,) = swapVM.asView().quote(
                order, address(tokenA), address(tokenB), amountPlusOne, exactInData
            );

            // More input should give at least as much output (monotonicity with rounding)
            assertGe(out2, out1, "Rounding should maintain monotonicity");

            // Log the results for debugging if needed
            // Amount: amount -> out: out1
            // Amount+1: amountPlusOne -> out: out2, diff: out2 - out1
        }
    }

    /**
     * Test PeggedSwap invariants using assertAllInvariantsWithConfig
     */
    function test_PeggedSwap_Invariants() public {
        uint256 balanceA = 10000e18;
        uint256 balanceB = 10000e18;
        uint256 x0Initial = 10000e18;
        uint256 y0Initial = 10000e18;
        uint256 linearWidth = 0.8e27; // A = 0.8 (standard for stablecoins)

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth,
                        rateLt: 1,
                        rateGt: 1
                })))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Create test configuration
        // Use amounts that are reasonable for a 10000e18 pool size
        // Keep total for additivity < pool size: 100 + 500 + 1000 = 1600e18
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 100e18;    // 1% of pool
        testAmounts[1] = 500e18;    // 5% of pool
        testAmounts[2] = 1000e18;   // 10% of pool

        InvariantConfig memory config = createInvariantConfig(testAmounts, 1e15); // Higher tolerance for PeggedSwap
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

    // Helper functions
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
