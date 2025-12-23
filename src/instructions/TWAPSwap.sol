// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Power } from "../libs/Power.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { LimitSwap } from "./LimitSwap.sol";

library TWAPSwapArgsBuilder {
    /// @notice Arguments for the TWAP swap
    /// @param balanceIn Expected amount of token1 (for initial price)
    /// @param balanceOut Total amount of token0 for TWAP
    /// @param startTime TWAP start time
    /// @param duration TWAP duration
    /// @param priceBumpAfterIlliquidity Price jump when liquidity was insufficient (1.10e18 means +10%)
    /// @param minTradeAmountOut Minimum trade size for token0
    struct TwapArgs {
        uint256 balanceIn;
        uint256 balanceOut;
        uint256 startTime;
        uint256 duration;
        uint256 priceBumpAfterIlliquidity;
        uint256 minTradeAmountOut;
    }

    function build(TwapArgs memory args) internal pure returns (bytes memory) {
        return abi.encode(args);
    }

    function parse(bytes calldata data) internal pure returns (TwapArgs calldata args) {
        assembly ("memory-safe") {
            args := data.offset // Zero-copy to calldata pointer casting
        }
    }
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
contract TWAPSwap is LimitSwap {
    using Math for uint256;
    using Power for uint256;
    using SafeCast for uint256;
    using ContextLib for Context;

    error TWAPSwapMinTradeAmountNotReached(uint256 amountIn, uint256 minAmount);
    error TWAPSwapTradeAmountExceedLiquidity(uint256 amountIn, uint256 available);

    struct LastSwap {
        uint256 amountIn;
        uint256 amountOut;
        uint256 timestamp;
    }

    mapping(bytes32 orderHash => LastSwap) public twapLastSwaps;

    constructor() {} // 0.01% decay per second for Dutch auction (price gets worse for maker) - price discovery

    /// @param argsData.TwapArgs | 192 bytes
    function _twap(Context memory ctx, bytes calldata argsData) internal {
        TWAPSwapArgsBuilder.TwapArgs calldata args = TWAPSwapArgsBuilder.parse(argsData);

        // Calculate available liquidity (linear unlocking)
        uint256 durationPassed = Math.min(block.timestamp - args.startTime, args.duration);
        uint256 unlocked = args.balanceOut * durationPassed / args.duration;
        uint256 sold = args.balanceOut - ctx.swap.balanceOut;
        uint256 available = unlocked - sold;

        // Calculate current output (first trade args)
        uint256 baseAmountOut = args.balanceOut;
        uint256 baseAmountIn = args.balanceIn;
        uint256 auctionStartTime = args.startTime;

        LastSwap memory lastSwap = twapLastSwaps[ctx.query.orderHash];
        if (lastSwap.timestamp > 0) {
            // Subsequent trades
            baseAmountOut = lastSwap.amountOut;
            baseAmountIn = lastSwap.amountIn;
            auctionStartTime = lastSwap.timestamp;

            // Check for illiquidity period (only relevant during TWAP duration)
            if (durationPassed < args.duration) {
                uint256 lastSwapAvailable = args.balanceOut * (auctionStartTime - args.startTime) / args.duration;

                (bool wasIlliquid, uint256 illiquidity0) = (args.minTradeAmountOut + sold).trySub(lastSwapAvailable);
                if (wasIlliquid) {
                    // Calculate illiquidity duration and max illiquidity duration
                    uint256 illiquidityDuration = illiquidity0 * args.duration / args.balanceOut;
                    uint256 maxIlliquidityDuration = args.minTradeAmountOut * args.duration / args.balanceOut;

                    // Apply proportional price bump
                    uint256 bumpRatio = Math.min(1e18, illiquidityDuration * 1e18 / maxIlliquidityDuration);
                    uint256 scaledBump = 1e18 + (args.priceBumpAfterIlliquidity - 1e18) * bumpRatio / 1e18;
                    baseAmountIn = baseAmountIn * scaledBump / 1e18;

                    // Adjust auction start time
                    auctionStartTime += illiquidityDuration;
                }
            }
        }

        uint256 decay = uint256(0.9999e18).pow(block.timestamp - auctionStartTime, 1e18);
        ctx.swap.balanceIn = baseAmountIn;
        ctx.swap.balanceOut = baseAmountOut * decay / 1e18;

        ctx.runLoop(); // Reuse LimitSwap logic for final amount calculation

        // Check minimum trade amount (only during TWAP duration) and available liquidity
        require(durationPassed >= args.duration || ctx.swap.amountOut >= args.minTradeAmountOut, TWAPSwapMinTradeAmountNotReached(ctx.swap.amountOut, args.minTradeAmountOut));
        require(ctx.swap.amountOut <= available, TWAPSwapTradeAmountExceedLiquidity(ctx.swap.amountOut, available));

        // Store trade data
        if (!ctx.vm.isStaticContext) {
            twapLastSwaps[ctx.query.orderHash] = LastSwap({
                amountIn: ctx.swap.amountIn,
                amountOut: ctx.swap.amountOut,
                timestamp: block.timestamp
            });
        }
    }
}
