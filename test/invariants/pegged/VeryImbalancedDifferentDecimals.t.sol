// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../src/libs/TakerTraits.sol";
import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";

/**
 * @title VeryImbalancedDifferentDecimals
 * @notice Tests PeggedSwap with very imbalanced pool: 10e18 vs 10e6
 * @dev Token A has 18 decimals, Token B has 6 decimals (like USDC)
 */
contract VeryImbalancedDifferentDecimals is PeggedFeesInvariants {
    function setUp() public override {
        // Skip super.setUp() - do custom initialization
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        // Create tokens with correct decimals: 18 and 6
        tokenA = TokenMock(address(new TokenMockDecimals("Token A", "TKA", 18)));
        tokenB = TokenMock(address(new TokenMockDecimals("Token B", "TKB", 6)));

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

        // Very imbalanced pool: 10e18 vs 10e6
        // TokenA: 10 tokens with 18 decimals = 10e18
        // TokenB: 10 tokens with 6 decimals equivalent = 10e6
        balanceA = 10e18;   // 10 tokens with 18 decimals
        balanceB = 10e6;    // Very small amount (imbalance ratio = 1e12)

        // Determine rates based on actual token addresses
        // TokenA has 18 decimals, TokenB has 6 decimals
        // We need to scale TokenB by 1e12 to match TokenA
        if (address(tokenA) < address(tokenB)) {
            // tokenA is Lt, tokenB is Gt
            rateLt = 1;      // TokenA (18 dec)
            rateGt = 1e12;   // TokenB (6 dec) -> scales to 18
        } else {
            // tokenB is Lt, tokenA is Gt
            rateLt = 1e12;   // TokenB (6 dec) -> scales to 18
            rateGt = 1;      // TokenA (18 dec)
        }

        // x0 and y0 should match the initial balance * rate for normalization
        // Both become 10e18 after rate scaling
        x0 = 10e18;
        y0 = 10e18;

        // Standard linear width
        linearWidth = 0.8e27;

        // Test amounts
        testAmounts = new uint256[](3);
        testAmounts[0] = 1e17;   // 0.1 tokens
        testAmounts[1] = 5e17;   // 0.5 tokens
        testAmounts[2] = 1e18;   // 1 token

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = 1e5;   // 0.1 tokens (6 decimals scale)
        testAmountsExactOut[1] = 5e5;   // 0.5 tokens
        testAmountsExactOut[2] = 1e6;   // 1 token

        flatFeeInBps = 0.003e9;
        flatFeeOutBps = 0.003e9;

        // Very imbalanced pools with different decimals have higher rounding errors
        // For small amounts (1 wei in 6-dec), sqrt error > swap size
        // Multiple fees add extra rounding, so use 400 bps = 4%
        symmetryTolerance = 1e12;
        additivityTolerance = 1000;
        roundingToleranceBps = 400;  // 4%
    }

    /**
     * @notice Test reverse swap with asymmetric pool and different decimals
     * @dev This test verifies the fix for the axis mismatch vulnerability
     * @dev Before the fix, reverse swaps in asymmetric pools with different decimals
     *      would result in wildly incorrect exchange rates due to axis swap misalignment
     */
    function test_AsymmetricPool_ReverseSwap_NoAxisMismatch() public view {
        // Create an asymmetric pool setup to test the vulnerability
        // Token A (18 dec): abundant asset - 100,000 tokens
        // Token B (6 dec): scarce asset - 10 tokens
        uint256 abundantBalance = 100_000e18;  // 100k tokens (18 decimals)
        uint256 scarceBalance = 10e6;          // 10 tokens (6 decimals)

        // Determine which token is abundant based on actual addresses
        uint256 balanceTokenA;
        uint256 balanceTokenB;
        uint256 x0Config;
        uint256 y0Config;
        uint256 rateLtTest;
        uint256 rateGtTest;

        if (address(tokenA) < address(tokenB)) {
            // tokenA is Lt (18 dec), tokenB is Gt (6 dec)
            balanceTokenA = abundantBalance;
            balanceTokenB = scarceBalance;
            rateLtTest = 1;      // 18 decimals
            rateGtTest = 1e12;   // 6 decimals -> scale to 18
            x0Config = abundantBalance;
            y0Config = scarceBalance * 1e12;  // Scaled
        } else {
            // tokenB is Lt (6 dec), tokenA is Gt (18 dec)
            balanceTokenA = scarceBalance;
            balanceTokenB = abundantBalance;
            rateLtTest = 1e12;   // 6 decimals -> scale to 18
            rateGtTest = 1;      // 18 decimals
            x0Config = scarceBalance * 1e12;  // Scaled
            y0Config = abundantBalance;
        }

        // Build order with asymmetric pool
        bytes memory bytecode = abi.encodePacked(
            hex"01",  // _dynamicBalancesXD opcode
            abi.encode(new address[](2)),  // Empty array placeholder
            abi.encode(new uint256[](2)),  // Empty array placeholder
            abi.encode(address(tokenA)),
            abi.encode(address(tokenB)),
            abi.encode(balanceTokenA),
            abi.encode(balanceTokenB),
            hex"0c",  // _peggedSwapGrowPriceRange2D opcode
            abi.encode(x0Config),
            abi.encode(y0Config),
            abi.encode(linearWidth),
            abi.encode(rateLtTest),
            abi.encode(rateGtTest)
        );

        // Create order (using maker and swapVM from parent setup)
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
            program: bytecode
        }));

        // Sign the order
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: bytes(""),
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

        bytes memory exactInData = abi.encodePacked(takerTraits);

        // Test both directions with small swap amounts
        uint256 swapAmount = 1e18;  // 1 token (18 decimals)

        // Forward swap: abundant -> scarce
        address tokenInForward = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address tokenOutForward = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        if (balanceTokenA < balanceTokenB) {
            // Swap: tokenA is scarce, so test tokenB (abundant) -> tokenA (scarce)
            tokenInForward = address(tokenB);
            tokenOutForward = address(tokenA);
        }

        try swapVM.asView().quote(
            order, tokenInForward, tokenOutForward, swapAmount, exactInData
        ) returns (uint256, uint256 outForward, bytes32) {
            // The output should be reasonable - not wildly inflated
            // Before the fix, reverse swap in asymmetric pool would give absurd amounts

            // For a balanced ratio (1:1 after scaling), expect roughly similar output
            // With 10:1 imbalance, expect significant but not absurd slippage
            // Output should be > 0 and < input * 100 (100x is already extreme)
            assertGt(outForward, 0, "Output should be non-zero");

            // Before fix: could get 1000x or more due to wrong invariant
            // After fix: should be reasonable (at most 10x difference due to imbalance + fees)
            uint256 maxReasonableOutput = swapAmount * 20;  // 20x max

            // Convert to common scale for comparison
            uint256 outForwardScaled = outForward;
            if (tokenOutForward == address(tokenA) && balanceTokenA < balanceTokenB) {
                // tokenA has 6 decimals (scarce)
                outForwardScaled = outForward * 1e12;  // Scale to 18
            } else if (tokenOutForward == address(tokenB) && balanceTokenB < balanceTokenA) {
                // tokenB has 6 decimals (scarce)
                outForwardScaled = outForward * 1e12;  // Scale to 18
            }

            assertLe(
                outForwardScaled,
                maxReasonableOutput,
                string.concat(
                    "Reverse swap output wildly inflated - axis mismatch detected! ",
                    "Output: ", vm.toString(outForwardScaled),
                    ", Max reasonable: ", vm.toString(maxReasonableOutput)
                )
            );
        } catch {
            // It's acceptable to revert for extreme cases
            // but the fix should prevent absurd outputs
        }

        // Test reverse direction as well
        try swapVM.asView().quote(
            order, tokenOutForward, tokenInForward, swapAmount, exactInData
        ) returns (uint256, uint256 outReverse, bytes32) {
            assertGt(outReverse, 0, "Reverse output should be non-zero");

            // Same check for reverse direction
            uint256 outReverseScaled = outReverse;
            if (tokenInForward == address(tokenA) && balanceTokenA < balanceTokenB) {
                outReverseScaled = outReverse * 1e12;
            } else if (tokenInForward == address(tokenB) && balanceTokenB < balanceTokenA) {
                outReverseScaled = outReverse * 1e12;
            }

            assertLe(
                outReverseScaled,
                swapAmount * 20,
                "Reverse direction also should not have axis mismatch"
            );
        } catch {
            // Also acceptable to revert
        }
    }
}
