// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Power } from "../libs/Power.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library DutchAuctionArgsBuilder {
    using Calldata for bytes;

    error DutchAuctionDecayFactorShouldBeLessThanOneE18(uint168 decayFactor);
    error DutchAuctionMissingStartTime();
    error DutchAuctionMissingDuration();
    error DutchAuctionMissingDecayFactor();

    function build(
        uint40 startTime,
        uint16 duration,
        uint64 decayFactor
    ) internal pure returns (bytes memory) {
        require(decayFactor < 1e18, DutchAuctionDecayFactorShouldBeLessThanOneE18(decayFactor));
        return abi.encodePacked(
            startTime,
            duration,
            decayFactor
        );
    }

    function parse(bytes calldata args) internal pure returns (
        uint40 startTime,
        uint16 duration,
        uint64 decayFactor
    ) {
        startTime = uint40(bytes5(args.slice(0, 5, DutchAuctionMissingStartTime.selector)));
        duration = uint16(bytes2(args.slice(5, 7, DutchAuctionMissingDuration.selector)));
        decayFactor = uint64(bytes8(args.slice(7, 15, DutchAuctionMissingDecayFactor.selector)));
    }
}

/**
 * @notice Dutch Auction instruction for time-based price decay with deadline
 * @dev Implements an exponential decay auction mechanism that works after any swap:
 * - Designed to be used after any swap instruction (LimitSwap, XYCSwap, etc.) which sets amounts
 * - Applies time-based decay to the amounts calculated by the previous swap
 * - Maker sells token0 and receives token1
 * - Price improves for taker over time through exponential decay until deadline
 * - Reverts if current time exceeds deadline
 * - Only works for 1=>0 swaps (token1 to token0)
 *
 * The decay factor determines the price reduction rate:
 * - 1.0e18 = no decay (constant price)
 * - 0.999e18 = 0.1% decay per second
 * - 0.99e18 = 1% decay per second
 * - 0.9e18 = 10% decay per second
 *
 * Example usage:
 * 1. Any swap instruction sets: 100 token1 → 1000 token0
 * 2. DutchAuction with decayFactor = 0.99e18, after 100 seconds:
 *    - exactIn: Taker gets ~2.73x more token0 for the same token1
 *    - exactOut: Taker needs only ~36.6% of initial token1
 * 3. After deadline, the auction expires and cannot be executed
 */
contract DutchAuction {
    using ContextLib for Context;
    using Math for uint256;
    using Power for uint256;

    error DutchAuctionShouldBeAppliedBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);
    error DutchAuctionExpired(uint256 currentTime, uint256 deadline);

    /// @notice Apply Dutch auction decay to shrink the amount in by shrinking the balance in
    function _dutchAuctionBalanceIn1D(Context memory ctx, bytes calldata args) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, DutchAuctionShouldBeAppliedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 startTime, uint256 duration, uint256 decayFactor) = DutchAuctionArgsBuilder.parse(args);
        require(block.timestamp <= startTime + duration, DutchAuctionExpired(block.timestamp, startTime + duration));
        uint256 elapsed = block.timestamp - startTime;
        uint256 decay = decayFactor.pow(elapsed, 1e18);
        ctx.swap.balanceIn = ctx.swap.balanceIn * decay / 1e18;
    }

    /// @notice Apply Dutch auction decay to increase the amount out by increasing the balance out
    function _dutchAuctionBalanceOut1D(Context memory ctx, bytes calldata args) internal view {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, DutchAuctionShouldBeAppliedBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut));

        (uint256 startTime, uint256 duration, uint256 decayFactor) = DutchAuctionArgsBuilder.parse(args);
        require(block.timestamp <= startTime + duration, DutchAuctionExpired(block.timestamp, startTime + duration));
        uint256 elapsed = block.timestamp - startTime;
        uint256 decay = decayFactor.pow(elapsed, 1e18);
        ctx.swap.balanceOut = ctx.swap.balanceOut * 1e18 / decay;
    }
}
