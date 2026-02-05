// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { SplineSwapMath } from "../libs/SplineSwapMath.sol";

/// @title SplineSwapArgsBuilder - Argument builder for SplineSwap instruction
/// @notice Builds and parses arguments for the SplineSwap instruction
/// @dev Uses packed encoding to fit within 255 bytes VM limit
library SplineSwapArgsBuilder {
    error SplineSwapInvalidArgsLength(uint256 length);
    error SplineSwapInvalidCapacities(uint256 sellCapacity, uint256 buyCapacity);

    /// @notice Arguments for the spline swap instruction
    /// @dev Packed layout (108 bytes total):
    ///   - initialPrice: uint256 (32 bytes) - Starting price P₀
    ///   - token0ToSell: uint256 (32 bytes) - Capacity for sell side
    ///   - token0ToBuy: uint256 (32 bytes) - Capacity for buy side
    ///   - sellRangeBps: uint16 (2 bytes) - Sell side range in bps
    ///   - buyRangeBps: uint16 (2 bytes) - Buy side range in bps
    ///   - sellAskBps: uint16 (2 bytes) - Ask spread in sell region
    ///   - sellBidBps: uint16 (2 bytes) - Bid spread in sell region
    ///   - buyAskBps: uint16 (2 bytes) - Ask spread in buy region
    ///   - buyBidBps: uint16 (2 bytes) - Bid spread in buy region
    struct Args {
        uint256 initialPrice;
        uint256 token0ToSell;
        uint256 token0ToBuy;
        uint16 sellRangeBps;
        uint16 buyRangeBps;
        uint16 sellAskBps;
        uint16 sellBidBps;
        uint16 buyAskBps;
        uint16 buyBidBps;
    }

    // Packed encoding: 3 * uint256 (96 bytes) + 6 * uint16 (12 bytes)
    // Total: 96 + 12 = 108 bytes (fits in uint8 limit of 255)
    uint256 private constant ARGS_LENGTH = 108;

    /// @notice Build encoded arguments for SplineSwap instruction
    /// @param args The arguments struct
    /// @return Encoded bytes for the instruction (108 bytes)
    function build(Args memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(
            args.initialPrice,               // 32 bytes (offset 0)
            args.token0ToSell,               // 32 bytes (offset 32)
            args.token0ToBuy,                // 32 bytes (offset 64)
            args.sellRangeBps,               // 2 bytes (offset 96)
            args.buyRangeBps,                // 2 bytes (offset 98)
            args.sellAskBps,                 // 2 bytes (offset 100)
            args.sellBidBps,                 // 2 bytes (offset 102)
            args.buyAskBps,                  // 2 bytes (offset 104)
            args.buyBidBps                   // 2 bytes (offset 106)
        );
        // Total: 108 bytes
    }

    /// @notice Parse encoded arguments from calldata
    /// @param data The encoded calldata
    /// @return args Parsed arguments
    function parse(bytes calldata data) internal pure returns (Args memory args) {
        require(data.length >= ARGS_LENGTH, SplineSwapInvalidArgsLength(data.length));

        // Parse uint256 values (32 bytes each)
        args.initialPrice = uint256(bytes32(data[0:32]));
        args.token0ToSell = uint256(bytes32(data[32:64]));
        args.token0ToBuy = uint256(bytes32(data[64:96]));

        // Parse uint16 values (2 bytes each) - big endian from bytes
        args.sellRangeBps = uint16(bytes2(data[96:98]));
        args.buyRangeBps = uint16(bytes2(data[98:100]));
        args.sellAskBps = uint16(bytes2(data[100:102]));
        args.sellBidBps = uint16(bytes2(data[102:104]));
        args.buyAskBps = uint16(bytes2(data[104:106]));
        args.buyBidBps = uint16(bytes2(data[106:108]));

        require(args.token0ToSell > 0 || args.token0ToBuy > 0, SplineSwapInvalidCapacities(args.token0ToSell, args.token0ToBuy));
    }
}


/// @title SplineSwap - Linear curve swap instruction for SwapVM
/// @notice Implements swap logic using Uniform density and Spline price formula
/// @dev Price = P₀ × (1 + range × x) where x is the normalized position
contract SplineSwap {
    using Calldata for bytes;
    using ContextLib for Context;

    error SplineSwapRecomputeDetected();
    error SplineSwapRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);
    error SplineSwapExceedsSellCapacity(uint256 amountOut, uint256 balanceOut);

    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10000;

    /// @notice Main instruction: SplineSwap with linear price curve
    /// @param ctx Swap context containing balances and amounts
    /// @param args Encoded SplineSwap configuration (108 bytes)
    /// @dev Supports both ExactIn and ExactOut modes
    function _splineSwapGrowPriceRange2D(Context memory ctx, bytes calldata args) internal pure {
        SplineSwapArgsBuilder.Args memory config = SplineSwapArgsBuilder.parse(args);

        uint256 balanceIn = ctx.swap.balanceIn;
        uint256 balanceOut = ctx.swap.balanceOut;

        require(balanceIn > 0 && balanceOut > 0, SplineSwapRequiresBothBalancesNonZero(balanceIn, balanceOut));

        // ╔═══════════════════════════════════════════════════════════════════════════╗
        // ║  SPLINE SWAP - LINEAR PRICE CURVE AMM                                     ║
        // ║                                                                           ║
        // ║  Position State:                                                          ║
        // ║    x = usedCapacity / capacity, normalized to [0, 1]                      ║
        // ║                                                                           ║
        // ║  Price Formula: P = P₀ × (1 + range × x)                                  ║
        // ║    - Uses Uniform density: f(x) = x                                       ║
        // ║    - Uses Spline price: P = P₀ × (1 + r × f(x))                           ║
        // ╚═══════════════════════════════════════════════════════════════════════════╝

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, SplineSwapRecomputeDetected());

            ctx.swap.amountOut = _calculateAmountOut(
                ctx.swap.amountIn,
                balanceOut,
                config
            );
        } else {
            require(ctx.swap.amountIn == 0, SplineSwapRecomputeDetected());

            require(ctx.swap.amountOut <= balanceOut, SplineSwapExceedsSellCapacity(ctx.swap.amountOut, balanceOut));

            ctx.swap.amountIn = _calculateAmountIn(
                ctx.swap.amountOut,
                balanceOut,
                config
            );
        }
    }

    /// @dev Calculate output amount for ExactIn swap
    function _calculateAmountOut(
        uint256 amountIn,
        uint256 balanceOut,
        SplineSwapArgsBuilder.Args memory config
    ) private pure returns (uint256 amountOut) {
        // Calculate average price for this swap
        uint256 avgPrice = _getAverageSwapPrice(
            amountIn,
            balanceOut,
            config,
            true // isExactIn
        );

        // amountOut = amountIn / avgPrice (price is token1/token0)
        // Floor division for output (protects maker)
        amountOut = amountIn * ONE / avgPrice;

        // Ensure we don't exceed available balance
        if (amountOut > balanceOut) {
            amountOut = balanceOut;
        }
    }

    /// @dev Calculate input amount for ExactOut swap
    function _calculateAmountIn(
        uint256 amountOut,
        uint256 balanceOut,
        SplineSwapArgsBuilder.Args memory config
    ) private pure returns (uint256 amountIn) {
        // Calculate average price for this swap
        uint256 avgPrice = _getAverageSwapPrice(
            amountOut,
            balanceOut,
            config,
            false // isExactIn
        );

        // amountIn = amountOut * avgPrice (price is token1/token0)
        // Ceiling division for input (protects maker)
        amountIn = Math.ceilDiv(amountOut * avgPrice, ONE);
    }

    /// @dev Get average price for a swap
    function _getAverageSwapPrice(
        uint256 amount,
        uint256 balanceOut,
        SplineSwapArgsBuilder.Args memory config,
        bool isExactIn
    ) private pure returns (uint256 avgPrice) {
        uint256 capacity = config.token0ToSell;
        uint256 rangeBps = config.sellRangeBps;
        uint256 spreadBps = config.sellAskBps;

        // Calculate used capacity = how much token0 has been sold
        uint256 usedCapacity = capacity > balanceOut ? capacity - balanceOut : 0;

        // Swap amount in terms of token0
        uint256 swapAmount;
        if (isExactIn) {
            // For ExactIn, estimate token0 amount based on initial price
            swapAmount = amount * ONE / config.initialPrice;
        } else {
            swapAmount = amount;
        }

        // Normalize positions to [0, 1e18]
        uint256 x0 = capacity > 0 ? usedCapacity * ONE / capacity : 0;
        uint256 x1 = capacity > 0 ? (usedCapacity + swapAmount) * ONE / capacity : 0;

        // Cap at ONE
        if (x0 > ONE) x0 = ONE;
        if (x1 > ONE) x1 = ONE;

        // Calculate average price using SplineSwapMath
        avgPrice = SplineSwapMath.getAveragePrice(
            config.initialPrice,
            rangeBps,
            x0,
            x1,
            true, // isSell - maker selling token0
            spreadBps
        );
    }
}
