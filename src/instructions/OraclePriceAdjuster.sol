// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

library OraclePriceAdjusterArgsBuilder {
    using Calldata for bytes;

    error OrcaclePriceAdjustedMaxPriceDecayShouldBeLessThanOneE18(uint64 maxPriceDecay);
    error OraclePriceAdjusterMissingOracleAddressArg();
    error OraclePriceAdjusterMissingOracleDecimalsArg();
    error OraclePriceAdjusterMissingMaxStalenessArg();
    error OraclePriceAdjusterMissingMaxPriceDecayArg();

    /// @param maxPriceDecay Maximum price decay coefficient (64 bits), e.g., 0.95e18 = 5% max discount
    /// @param maxStaleness Maximum allowed staleness for oracle data in seconds (16 bits), 0 = no staleness check
    /// @param oracleDecimals Number of decimals the oracle uses (8 bits), e.g., 8 for USD prices
    /// @param oracleAddress Address of the Chainlink price oracle contract (160 bits) - stored in lower bits
    function build(
        uint64 maxPriceDecay,
        uint16 maxStaleness,
        uint8 oracleDecimals,
        address oracleAddress
    ) internal pure returns (bytes memory) {
        require(maxPriceDecay < 1e18, OrcaclePriceAdjustedMaxPriceDecayShouldBeLessThanOneE18(maxPriceDecay));
        return abi.encodePacked(
            maxPriceDecay,
            maxStaleness,
            oracleDecimals,
            oracleAddress
        );
    }

    function parse(bytes calldata args) internal pure returns (
        uint64 maxPriceDecay,
        uint16 maxStaleness,
        uint8 oracleDecimals,
        address oracleAddress
    ) {
        maxPriceDecay = uint64(bytes8(args.slice(0, 8, OraclePriceAdjusterMissingMaxPriceDecayArg.selector)));
        maxStaleness = uint16(bytes2(args.slice(8, 10, OraclePriceAdjusterMissingMaxStalenessArg.selector)));
        oracleDecimals = uint8(bytes1(args.slice(10, 11, OraclePriceAdjusterMissingOracleDecimalsArg.selector)));
        oracleAddress = address(bytes20(args.slice(11, 31, OraclePriceAdjusterMissingOracleAddressArg.selector)));
    }
}

/**
 * @notice Oracle Price Adjuster instruction for dynamic price adjustment based on Chainlink price feeds
 * @dev Adjusts swap prices to match Chainlink oracle prices within safe bounds:
 * - Works only for 1=>0 swaps (token1 to token0), compatible with LimitSwap and other swap instructions
 * - Fetches current market price from a Chainlink oracle (AggregatorV3Interface)
 * - Adjusts the swap price towards the oracle price within maxPriceDecay limits
 * - Ensures the adjustment is always favorable for the taker
 * - Handles different decimal places from Chainlink oracles (e.g., 8 decimals for USD prices)
 *
 * This creates adaptive orders that automatically track market prices while maintaining
 * safety bounds to prevent excessive slippage or manipulation.
 *
 * Example usage:
 * 1. LimitSwap sets base price: 1 ETH for 3000 USDC
 * 2. OraclePriceAdjuster with Chainlink ETH/USD oracle: 1 ETH = 3100 USD, maxPriceDecay=0.95e18 (5% max)
 * 3. exactIn: Taker gets more ETH (up to 5% improvement)
 * 4. exactOut: Taker pays less USDC (up to 5% discount)
 */
contract OraclePriceAdjuster {
    using Math for uint256;
    using SafeCast for int256;
    using ContextLib for Context;

    error OraclePriceAdjusterShouldBeAppliedAfterSwap();
    error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness);

    /// @notice Adjust swap amounts based on oracle price
    /// @param args.oracleAddress  | 20 bytes
    /// @param args.oracleDecimals | 1 byte
    /// @param args.maxStaleness   | 2 bytes
    /// @param args.maxPriceDecay  | 8 bytes
    function _oraclePriceAdjuster1D(Context memory ctx, bytes calldata args) internal view {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, OraclePriceAdjusterShouldBeAppliedAfterSwap());

        (
            uint64 maxPriceDecay,
            uint16 maxStaleness,
            uint8 oracleDecimals,
            address oracleAddress
        ) = OraclePriceAdjusterArgsBuilder.parse(args);

        // Get oracle price from Chainlink
        IPriceOracle oracle = IPriceOracle(oracleAddress);

        // Get latest price data from Chainlink
        (, int256 answer, , uint256 updatedAt, ) = oracle.latestRoundData();

        // Check if oracle data is fresh using configured staleness threshold
        // If maxStaleness is 0, skip the staleness check
        require(maxStaleness == 0 || block.timestamp <= updatedAt + maxStaleness, OraclePriceAdjusterOraclePriceStale(block.timestamp, updatedAt, maxStaleness));

        // If oracleDecimals is 0, fetch from oracle (backward compatibility)
        if (oracleDecimals == 0) {
            oracleDecimals = oracle.decimals();
        }

        // Convert oracle price to 1e18 scale using provided decimals
        uint256 oraclePrice = answer.toUint256();
        if (oracleDecimals < 18) {
            oraclePrice = oraclePrice * 10**(18 - oracleDecimals);
        } else if (oracleDecimals > 18) {
            oraclePrice = oraclePrice / 10**(oracleDecimals - 18);
        }

        // Calculate current swap price (token0 per token1)
        // Price = amountOut (token0) / amountIn (token1)
        uint256 currentPrice = (ctx.swap.amountOut * 1e18) / ctx.swap.amountIn;

        // Only adjust if oracle price is better for taker
        if (oraclePrice > currentPrice) {
            // Oracle shows token0 is worth more token1, so taker should get better deal

            if (ctx.query.isExactIn) {
                // exactIn: Taker provides fixed token1, should get more token0
                // Increase amountOut proportionally, but cap at maxIncrease
                uint256 priceRatio = (oraclePrice * 1e18) / currentPrice;
                uint256 maxIncrease = (2e18 - maxPriceDecay); // Mirror of decay for increase
                uint256 adjustment = Math.min(priceRatio, maxIncrease);
                ctx.swap.amountOut = (ctx.swap.amountOut * adjustment) / 1e18;
            } else {
                // exactOut: Taker wants fixed token0, should pay less token1
                // Reduce amountIn proportionally, but cap at maxPriceDecay
                uint256 priceRatio = (currentPrice * 1e18) / oraclePrice;
                uint256 adjustment = Math.max(priceRatio, maxPriceDecay);
                ctx.swap.amountIn = (ctx.swap.amountIn * adjustment).ceilDiv(1e18);
            }
        }
        // If oracle price <= current price, no adjustment (already favorable for taker)
    }
}
