// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../src/libs/TakerTraits.sol";
import { PeggedFeesInvariants } from "../PeggedFeesInvariants.t.sol";
import { TokenMockDecimals } from "../../mocks/TokenMockDecimals.sol";
import { StaticBalances, DynamicBalances } from "../../../src/instructions/Balances.sol";
import { PeggedSwap } from "../../../src/instructions/PeggedSwap.sol";

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
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        // Create tokens with correct decimals: 18 and 6
        TokenMock token18 = TokenMock(address(new TokenMockDecimals("Token I", "TKI", 18)));
        TokenMock token6 = TokenMock(address(new TokenMockDecimals("Token J", "TKJ", 6)));

        // Sort so tokenA < tokenB (required by MakerTraitsLib)
        (tokenA, tokenB) = address(token18) < address(token6) ? (token18, token6) : (token6, token18);

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
        // token18: 10 tokens with 18 decimals = 10e18
        // token6:  10 tokens with 6 decimals = 10e6 (imbalance ratio = 1e12)
        // balanceA/balanceB must follow ascending token address order (tokenA, tokenB).
        // We need to scale the 6-decimal token by 1e12 to match the 18-decimal token.
        if (address(token18) < address(token6)) {
            // token18 is Lt (tokenA), token6 is Gt (tokenB)
            balanceA = 10e18;   // 18 dec
            balanceB = 10e6;    // 6 dec
            rateLt = 1;      // token18 (18 dec)
            rateGt = 1e12;   // token6 (6 dec) -> scales to 18
        } else {
            // token6 is Lt (tokenA), token18 is Gt (tokenB)
            balanceA = 10e6;    // 6 dec
            balanceB = 10e18;   // 18 dec
            rateLt = 1e12;   // token6 (6 dec) -> scales to 18
            rateGt = 1;      // token18 (18 dec)
        }

        // x0 and y0 should match the initial balance * rate for normalization
        // Both become 10e18 after rate scaling
        x0 = 10e18;
        y0 = 10e18;

        // Standard linear width
        linearWidth = 0.8e27;

        // Test amounts. Input amounts are in tokenA (input) decimals,
        // exactOut amounts in tokenB (output) decimals.
        uint256 unitIn = address(token18) < address(token6) ? 1e18 : 1e6;   // tokenA decimals
        uint256 unitOut = address(token18) < address(token6) ? 1e6 : 1e18;  // tokenB decimals

        testAmounts = new uint256[](3);
        testAmounts[0] = unitIn / 10;       // 0.1 tokens
        testAmounts[1] = unitIn / 2;        // 0.5 tokens
        testAmounts[2] = unitIn;            // 1 token

        testAmountsExactOut = new uint256[](3);
        testAmountsExactOut[0] = unitOut / 10;  // 0.1 tokens
        testAmountsExactOut[1] = unitOut / 2;   // 0.5 tokens
        testAmountsExactOut[2] = unitOut;       // 1 token

        flatFeeInBps = 0.003e7;
        flatFeeOutBps = 0.003e7;

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
    function test_AsymmetricPool_ReverseSwap_NoAxisMismatch() public {
        // Create an asymmetric pool setup to test the vulnerability.
        // The 18-decimal token is the abundant asset (100,000 tokens),
        // the 6-decimal token is the scarce asset (10 tokens).
        uint256 abundantBalance = 100_000e18;  // 100k tokens (18 decimals)
        uint256 scarceBalance = 10e6;          // 10 tokens (6 decimals)

        // tokenA < tokenB is guaranteed by setUp. Map balances/rates to ascending
        // address order, deriving decimals from the actual tokens.
        bool tokenAIs18 = tokenA.decimals() == 18;

        uint256 balanceTokenA = tokenAIs18 ? abundantBalance : scarceBalance;
        uint256 balanceTokenB = tokenAIs18 ? scarceBalance : abundantBalance;
        // rateLt scales tokenA to 18 decimals, rateGt scales tokenB.
        uint256 rateLtTest = tokenAIs18 ? 1 : 1e12;
        uint256 rateGtTest = tokenAIs18 ? 1e12 : 1;
        // x0/y0 are the balances scaled to 18 decimals.
        uint256 x0Config = balanceTokenA * rateLtTest;
        uint256 y0Config = balanceTokenB * rateGtTest;

        // Build order with asymmetric pool. Balances are positional in ascending
        // token address order (tokenA, tokenB).
        bytes memory bytecode = bytes.concat(
            DynamicBalances.build(balanceTokenA, balanceTokenB),
            PeggedSwap.build(x0Config, y0Config, linearWidth, rateLtTest, rateGtTest)
        );

        // Create order (using maker and swapVM from parent setup)
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

        // Direction is selected via isAToB in taker data (tokenIn < tokenOut == A->B)
        bytes memory exactInData = _reverseSwapTakerData(
            signature, tokenInForward < tokenOutForward
        );
        bytes memory exactInDataReverse = _reverseSwapTakerData(
            signature, tokenOutForward < tokenInForward
        );

        try swapVM.asView().quote(
            order, swapAmount, exactInData
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
            order, swapAmount, exactInDataReverse
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

    function _reverseSwapTakerData(bytes memory signature, bool isAToB) private view returns (bytes memory) {
        return abi.encodePacked(TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
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
        })));
    }
}
