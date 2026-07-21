// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Power } from "../libs/Power.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice TWAPSwap opcode, TWAP selling strategy with exponential dutch auction and illiquidity handling
/// @dev Encoding: [uint256 balanceIn, uint256 balanceOut, uint256 startTime, uint256 duration, uint256 priceBumpAfterIlliquidity, uint256 minTradeAmountOut]
/// @dev The opcode is expected to be executed only once in strategy flow, storage vars are written by the first-met opcode instance
library TWAPSwap {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;
    using Power for uint256;
    using Math for uint256;

    error TWAPSwapMinTradeAmountNotReached(uint256 amountIn, uint256 minAmount);
    error TWAPSwapTradeAmountExceedLiquidity(uint256 amountIn, uint256 available);
    error TWAPSwapInvalidBalances(uint256 balanceIn, uint256 balanceOut);
    error TWAPSwapInvalidDuration(uint256 duration);
    error TWAPSwapInvalidPriceBump(uint256 priceBumpAfterIlliquidity);

    Opcode constant opcode = Opcode.TWAPSwap;

    uint256 constant ONE = 1e18;
    uint256 constant DECAY_FACTOR = 0.9999e18;

    struct LastSwap {
        uint256 amountIn;
        uint256 amountOut;
        uint256 timestamp;
        uint256 totalSold;
    }

    struct Storage {
        mapping(bytes32 orderHash => LastSwap) lastSwap;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.TWAPSwap;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @param balanceIn Expected amount of token1 (for initial price)
    /// @param balanceOut Total amount of token0 for TWAP
    /// @param startTime TWAP start time
    /// @param duration TWAP duration
    /// @param priceBumpAfterIlliquidity Price jump when liquidity was insufficient (1.10e18 means +10%)
    /// @param minTradeAmountOut Minimum trade size for token0
    function build(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 startTime,
        uint256 duration,
        uint256 priceBumpAfterIlliquidity,
        uint256 minTradeAmountOut
    ) internal pure returns (bytes memory) {
        require(balanceIn > 0 && balanceOut > 0, TWAPSwapInvalidBalances(balanceIn, balanceOut));
        require(duration > 0, TWAPSwapInvalidDuration(duration));
        require(priceBumpAfterIlliquidity >= ONE, TWAPSwapInvalidPriceBump(priceBumpAfterIlliquidity));

        bytes memory args = abi.encodePacked(balanceIn, balanceOut, startTime, duration, priceBumpAfterIlliquidity, minTradeAmountOut);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 startTime,
        uint256 duration,
        uint256 priceBumpAfterIlliquidity,
        uint256 minTradeAmountOut
    ) {
        balanceIn = args.at(0).asU256();
        balanceOut = args.at(32).asU256();
        startTime = args.at(64).asU256();
        duration = args.at(96).asU256();
        priceBumpAfterIlliquidity = args.at(128).asU256();
        minTradeAmountOut = args.at(160).asU256();
    }

    /**
     * @notice TWAP Hook with exponential dutch auction and illiquidity handling
     * @dev Implements a TWAP (Time-Weighted Average Price) selling strategy with the following features:
     * - Linear liquidity unlocking over time
     * - Exponential price decay (dutch auction) for better price discovery
     * - Automatic price bump after periods of insufficient liquidity
     * - Minimum trade size enforcement during TWAP duration
     *
     * Minimum Trade Size (minTradeAmountOut):
     * The minimum trade size protects against gas cost impact on execution price.
     * It should be set 1000x+ larger than the expected transaction fees on the deployment network.
     *
     * For example:
     * - Ethereum mainnet with $50 gas cost → minTradeAmountOut should be $50,000+
     * - Arbitrum/Optimism with $0.50 gas cost → minTradeAmountOut should be $500+
     * - BSC/Polygon with $0.05 gas cost → minTradeAmountOut should be $50+
     *
     * This ensures gas costs remain negligible (<0.1%) relative to trade value.
     *
     * Price Bump Configuration Guidelines:
     *
     * The priceBumpAfterIlliquidity compensates for mandatory waiting periods due to linear unlocking.
     * Time to unlock minTradeAmountOut = (minTradeAmountOut / balance0) * duration
     *
     * Examples:
     * - minTradeAmountOut = 0.1% of balance0, duration = 24h → 14.4 min to unlock each min trade
     *   Recommended bump: 1.05e18 - 1.10e18 (5-10%)
     *
     * - minTradeAmountOut = 1% of balance0, duration = 24h → 14.4 min to unlock each min trade
     *   Recommended bump: 1.10e18 - 1.20e18 (10-20%)
     *
     * - minTradeAmountOut = 5% of balance0, duration = 24h → 1.2 hours to unlock each min trade
     *   Recommended bump: 1.30e18 - 1.50e18 (30-50%)
     *
     * - minTradeAmountOut = 10% of balance0, duration = 24h → 2.4 hours to unlock each min trade
     *   Recommended bump: 1.50e18 - 2.00e18 (50-100%)
     *
     * Additional factors to consider:
     * - Network gas costs: Higher gas requires larger bumps
     * - Pair volatility: Volatile pairs need larger bumps to compensate for price risk
     * - Market depth: Thin markets may need higher bumps to attract arbitrageurs
     *
     * The bump should ensure profitability after the mandatory waiting period.
     */
    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();

        (
            uint256 balanceIn,
            uint256 balanceOut,
            uint256 startTime,
            uint256 duration,
            uint256 priceBumpAfterIlliquidity,
            uint256 minTradeAmountOut
        ) = parse(args);

        // Calculate available liquidity (linear unlocking)
        uint256 durationPassed = Math.min(block.timestamp - startTime, duration);
        uint256 unlocked = balanceOut * durationPassed / duration;

        LastSwap storage lastSwap = $.lastSwap[ctx.query.orderHash];
        uint256 sold = lastSwap.totalSold; // Use cumulative sold from storage
        uint256 available = unlocked - sold;

        uint256 baseAmountIn;
        uint256 baseAmountOut;
        uint256 auctionStartTime = lastSwap.timestamp;

        if (auctionStartTime == 0) { 
            // Calculate current output (first trade args)
            auctionStartTime = startTime;
            baseAmountIn = balanceIn;
            baseAmountOut = balanceOut;
        } else {
            // Subsequent trades
            baseAmountIn = lastSwap.amountIn;
            baseAmountOut = lastSwap.amountOut;

            // Check for illiquidity period (only relevant during TWAP duration)
            if (durationPassed < duration) {
                uint256 lastSwapAvailable = balanceOut * (auctionStartTime - startTime) / duration;

                (bool wasIlliquid, uint256 illiquidity0) = (minTradeAmountOut + sold).trySub(lastSwapAvailable);
                if (wasIlliquid) {
                    // Calculate illiquidity duration and max illiquidity duration
                    uint256 illiquidityDuration = illiquidity0 * duration / balanceOut;
                    uint256 maxIlliquidityDuration = minTradeAmountOut * duration / balanceOut;

                    // Apply proportional price bump
                    uint256 bumpRatio = Math.min(ONE, illiquidityDuration * ONE / maxIlliquidityDuration);
                    uint256 scaledBump = ONE + (priceBumpAfterIlliquidity - ONE) * bumpRatio / ONE;
                    baseAmountIn = baseAmountIn * scaledBump / ONE;

                    // Adjust auction start time
                    auctionStartTime += illiquidityDuration;
                }
            }
        }

        uint256 decay = DECAY_FACTOR.pow(block.timestamp - auctionStartTime, ONE);
        ctx.swap.balanceIn = baseAmountIn;
        ctx.swap.balanceOut = baseAmountOut * decay / ONE;

        ctx.runLoop(); // Reuse LimitSwap logic for final amount calculation

        // Check minimum trade amount (only during TWAP duration) and available liquidity
        require(durationPassed >= duration || ctx.swap.amountOut >= minTradeAmountOut, TWAPSwapMinTradeAmountNotReached(ctx.swap.amountOut, minTradeAmountOut));
        require(ctx.swap.amountOut <= available, TWAPSwapTradeAmountExceedLiquidity(ctx.swap.amountOut, available));

        // Update cumulative sold
        sold += ctx.swap.amountOut;

        // Store trade data
        if (!ctx.vm.isStaticContext) {
            $.lastSwap[ctx.query.orderHash] = LastSwap({
                amountIn: ctx.swap.amountIn,
                amountOut: ctx.swap.amountOut,
                timestamp: block.timestamp,
                totalSold: sold
            });
        }
    }
}

contract TWAPSwapExternal {
    function twapLastSwap(bytes32 orderHash) external view returns (uint256 amountIn, uint256 amountOut, uint256 timestamp, uint256 totalSold) {
        TWAPSwap.Storage storage $ = TWAPSwap.store();
        TWAPSwap.LastSwap storage lastSwap = $.lastSwap[orderHash];

        amountIn = lastSwap.amountIn;
        amountOut = lastSwap.amountOut;
        timestamp = lastSwap.timestamp;
        totalSold = lastSwap.totalSold;
    }
}
