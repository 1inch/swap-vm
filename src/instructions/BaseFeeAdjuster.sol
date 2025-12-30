// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library BaseFeeAdjusterArgsBuilder {
    using Calldata for bytes;

    error BaseFeeAdjusterMissingBaseGasPriceArg();
    error BaseFeeAdjusterMissingEthPriceArg();
    error BaseFeeAdjusterMissingGasAmountArg();
    error BaseFeeAdjusterMissingMaxPriceDecayArg();

    /// @param baseGasPrice Base gas price for comparison (64 bits)
    /// @param ethToToken1Price ETH price in token1 units (96 bits), e.g., 3000e18 for 1 ETH = 3000 USDC
    /// @param gasAmount Gas amount to compensate for (24 bits)
    /// @param maxPriceDecay Maximum price decay coefficient (64 bits), e.g., 0.99e18 = 1% max discount
    function build(
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            baseGasPrice,
            ethToToken1Price,
            gasAmount,
            maxPriceDecay
        );
    }

    function parse(bytes calldata args) internal pure returns (
        uint64 baseGasPrice,
        uint96 ethToToken1Price,
        uint24 gasAmount,
        uint64 maxPriceDecay
    ) {
        baseGasPrice = uint64(bytes8(args.slice(0, 8, BaseFeeAdjusterMissingBaseGasPriceArg.selector)));
        ethToToken1Price = uint96(bytes12(args.slice(8, 20, BaseFeeAdjusterMissingEthPriceArg.selector)));
        gasAmount = uint24(bytes3(args.slice(20, 23, BaseFeeAdjusterMissingGasAmountArg.selector)));
        maxPriceDecay = uint64(bytes8(args.slice(23, 31, BaseFeeAdjusterMissingMaxPriceDecayArg.selector)));
    }
}

/**
 * @notice Base Fee Gas Price Adjuster instruction for dynamic price adjustment based on network gas costs
 * @dev Adjusts swap prices based on current gas conditions to compensate for transaction costs:
 * - Works only for 1=>0 swaps (token1 to token0), compatible with LimitSwap and DutchAuction
 * - When gas price exceeds base level, maker improves the price to compensate taker for gas costs
 * - The adjustment is proportional to the difference between current and base gas prices
 * - Maximum adjustment is limited by maxPriceDecay parameter
 *
 * This creates adaptive limit orders that automatically become more attractive during high gas periods,
 * ensuring execution even when transaction costs are elevated.
 *
 * Example usage:
 * 1. LimitSwap sets base price: 1 ETH for 3000 USDC
 * 2. BaseFeeAdjuster with baseGasPrice=20 gwei, current=100 gwei
 * 3. Extra cost = 80 gwei * 150k gas * 3000 USDC/ETH = 36 USDC
 * 4. With maxPriceDecay=0.99e18 (1% max), final price: 1 ETH for 2970 USDC
 */
contract BaseFeeAdjuster {
    using Math for uint256;
    using ContextLib for Context;

    error BaseFeeAdjusterShouldBeAppliedAfterSwap();

    /// @notice Adjust swap amounts based on current gas price relative to base
    /// @param ctx Swap state with amounts from previous instruction
    /// @param args Packed: baseGasPrice (64) | ethToToken1Price (96) | gasAmount (24) | maxPriceDecay (64)
    function _baseFeeAdjuster1D(Context memory ctx, bytes calldata args) internal view {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, BaseFeeAdjusterShouldBeAppliedAfterSwap());

        (
            uint64 baseGasPrice,
            uint96 ethToToken1Price,
            uint24 gasAmount,
            uint64 maxPriceDecay
        ) = BaseFeeAdjusterArgsBuilder.parse(args);

        // Only adjust if current gas exceeds base
        if (block.basefee > baseGasPrice) {
            // Calculate extra gas cost in token1
            uint256 extraGasCost = (block.basefee - baseGasPrice) * gasAmount;
            uint256 extraCostInToken1 = (extraGasCost * ethToToken1Price) / 1e18;

            if (ctx.query.isExactIn) {
                // exactIn: Increase amountOut (taker gets more token0)
                uint256 priceIncrease = 1e18 + (extraCostInToken1 * 1e18 / ctx.swap.amountOut);
                uint256 maxIncrease = (2e18 - maxPriceDecay); // Mirror of decay for increase
                priceIncrease = Math.min(priceIncrease, maxIncrease);
                ctx.swap.amountOut = (ctx.swap.amountOut * priceIncrease) / 1e18;
            } else {
                // exactOut: Reduce amountIn (taker pays less token1)
                uint256 priceDecay = 1e18 - (extraCostInToken1 * 1e18 / ctx.swap.amountIn);
                priceDecay = Math.max(priceDecay, maxPriceDecay);
                ctx.swap.amountIn = (ctx.swap.amountIn * priceDecay).ceilDiv(1e18);
            }
        }
    }
}
