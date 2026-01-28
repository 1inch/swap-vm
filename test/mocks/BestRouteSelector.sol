// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context, SwapQuery, SwapRegisters, VM, ContextLib } from "../../src/libs/VM.sol";
import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";

/**
 * @title BestRouteSelector
 * @notice Smart routing: tries multiple DIFFERENT strategies, selects best output
 * @dev Real trading algorithm via Extruction mechanism
 *
 *      Args format: [numBranches:uint8, strategy1:bytes, strategy2:bytes, ...]
 *
 *      Key insight: Each strategy is DIFFERENT swap algorithm on SAME initial balances
 *      - Strategy 1: XYC + Concentrated + FeeIn
 *      - Strategy 2: Pegged + FeeIn
 *      - Strategy 3: XYC only
 *      → No XYCSwapRecomputeDetected because strategies are DIFFERENT!
 *
 *      Algorithm:
 *      1. Parse N strategy bytecodes (each is complete sub-program)
 *      2. Execute each strategy independently via runLoop with SAME initial balances
 *      3. Compare outputs from all strategies
 *      4. Return result from strategy with maximum amountOut
 *
 *      Use cases:
 *      - Maker encodes multiple strategies (XYC, Pegged, Concentrated)
 *      - System automatically selects best strategy at execution time
 *      - Adapts to current market conditions (liquidity, fees, price impact)
 *      - Each strategy operates on same pool balances but different curve logic
 */
contract BestRouteSelector is OpcodesDebug {
    using ContextLib for Context;

    error BestRouteSelectorInvalidArgs();
    error BestRouteSelectorNoBranches();

    constructor(address aqua) OpcodesDebug(aqua) {}

    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    ) {
        // Args format: [numBranches:uint8, len1:uint16, strategy1:bytes, len2:uint16, strategy2:bytes, ...]
        require(args.length >= 1, BestRouteSelectorInvalidArgs());

        uint8 numBranches = uint8(args[0]);
        require(numBranches > 0, BestRouteSelectorNoBranches());

        // Track best result
        uint256 bestAmountOut = 0;
        SwapRegisters memory bestResult = swap;

        uint256 offset = 1;

        // Try each strategy
        for (uint256 i = 0; i < numBranches; i++) {
            require(offset + 2 <= args.length, BestRouteSelectorInvalidArgs());

            // Read strategy length
            uint16 strategyLen = uint16(bytes2(args[offset:offset + 2]));
            offset += 2;

            require(offset + strategyLen <= args.length, BestRouteSelectorInvalidArgs());

            // Extract strategy bytecode
            bytes calldata strategy = args[offset:offset + strategyLen];
            offset += strategyLen;

            // Reconstruct Context for this strategy
            // Key: Each strategy gets SAME initial balances but DIFFERENT program
            Context memory ctx = Context({
                vm: VM({
                    isStaticContext: isStaticContext,
                    nextPC: 0,  // Start from beginning of strategy
                    programPtr: CalldataPtrLib.from(strategy),
                    takerArgsPtr: CalldataPtrLib.from(takerData),
                    opcodes: _opcodes()
                }),
                query: query,
                swap: swap  // Reset to initial balances for each strategy!
            });

            // Execute this strategy
            (, uint256 amountOut) = ctx.runLoop();

            // Check if this strategy is better
            if (amountOut > bestAmountOut) {
                bestAmountOut = amountOut;
                bestResult = SwapRegisters({
                    balanceIn: swap.balanceIn,
                    balanceOut: swap.balanceOut,
                    amountIn: swap.amountIn,
                    amountOut: amountOut
                });
            }
        }

        // Return best result
        updatedSwap = bestResult;
        updatedNextPC = nextPC;
        choppedLength = 0;

        return (updatedNextPC, choppedLength, updatedSwap);
    }
}
