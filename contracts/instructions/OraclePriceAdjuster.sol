// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

/// @notice OraclePriceAdjusterBalanceIn opcode, shifts an exact-sell auction by the market price movement
/// @dev Encoding: [uint128 marketPrice, uint8 decimalsConfig,
///   [uint8 config, uint24 maxStaleness, address oracle] packedFeeds[1..2]]
///   decimalsConfig: highest bit is scaleDown, lower 7 bits are the token decimals difference
///   config: highest bit is isDenominator, lower 7 bits are oracleDecimals
/// @dev Should be applied after balance-in surcharge discounts and before the swap curve
library OraclePriceAdjusterBalanceIn {
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceIn;

    function sizeOf(uint128, uint8, uint8, bytes memory packedFeeds) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 16 + 1 + packedFeeds.length;
    }

    function build(
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory packedFeeds
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds)),
            marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory packedFeeds
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = OraclePriceAdjuster.build(ptr, marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint128 marketPrice, uint8 decimalsConfig) = OraclePriceAdjuster.parse(args);
        uint256 oraclePrice = OraclePriceAdjuster.read(args);
        if (oraclePrice <= marketPrice) return;

        uint256 priceDelta = OraclePriceAdjuster.scalePrice(oraclePrice - marketPrice, decimalsConfig);
        uint256 balanceDelta = ctx.swap.balanceOut.mulDiv(
            priceDelta,
            OraclePriceAdjuster.ONE,
            Math.Rounding.Ceil
        );

        ctx.swap.surcharge += balanceDelta;
        ctx.swap.balanceIn += balanceDelta;
    }
}

/// @notice OraclePriceAdjusterBalanceOut opcode, shifts an exact-buy auction by the market price movement
/// @dev Encoding: [uint128 marketPrice, uint8 decimalsConfig,
///   [uint8 config, uint24 maxStaleness, address oracle] packedFeeds[1..2]]
///   decimalsConfig: highest bit is scaleDown, lower 7 bits are the token decimals difference
///   config: highest bit is isDenominator, lower 7 bits are oracleDecimals
/// @dev Should be applied after balance-out surcharge discounts and before the swap curve
library OraclePriceAdjusterBalanceOut {
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceOut;

    function sizeOf(uint128, uint8, uint8, bytes memory packedFeeds) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 16 + 1 + packedFeeds.length;
    }

    function build(
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory packedFeeds
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds)),
            marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory packedFeeds
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = OraclePriceAdjuster.build(ptr, marketPrice, tokenInDecimals, tokenOutDecimals, packedFeeds);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint128 marketPrice, uint8 decimalsConfig) = OraclePriceAdjuster.parse(args);
        uint256 oraclePrice = OraclePriceAdjuster.read(args);
        if (oraclePrice <= marketPrice || ctx.swap.balanceOut == 0) return;

        uint256 priceDelta = OraclePriceAdjuster.scalePrice(oraclePrice - marketPrice, decimalsConfig);
        uint256 currentPrice = ctx.swap.balanceIn.mulDiv(
            OraclePriceAdjuster.ONE,
            ctx.swap.balanceOut,
            Math.Rounding.Ceil
        );
        uint256 balanceOut = ctx.swap.balanceIn.mulDiv(
            OraclePriceAdjuster.ONE,
            currentPrice + priceDelta
        );

        ctx.swap.surcharge += ctx.swap.balanceOut - balanceOut;
        ctx.swap.balanceOut = balanceOut;
    }
}

library OraclePriceAdjuster {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    error OraclePriceAdjusterInvalidMarketPrice(uint128 marketPrice);
    error OraclePriceAdjusterInvalidOraclePrice(int256 oraclePrice);
    error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint24 maxStaleness);
    error OraclePriceAdjusterInvalidOracleDecimals(uint8 oracleDecimals);
    error OraclePriceAdjusterInvalidTokenDecimals(uint8 tokenInDecimals, uint8 tokenOutDecimals);
    error OraclePriceAdjusterInvalidFeedsLength(uint256 feedsLength);
    uint256 constant ONE = 1e18;
    uint256 private constant FIXED_ARGS_LENGTH = 16 + 1;
    uint256 private constant FEED_LENGTH = 24;
    uint8 private constant MAX_DECIMALS = 18;
    uint8 private constant DENOMINATOR_FLAG = 1 << 7;
    uint8 private constant SCALE_DOWN_FLAG = 1 << 7;
    uint8 private constant DECIMALS_MASK = DENOMINATOR_FLAG - 1;

    function build(
        MemoryPtr ptr,
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory packedFeeds
    ) internal pure returns (MemoryPtr) {
        require(marketPrice != 0, OraclePriceAdjusterInvalidMarketPrice(marketPrice));
        require(
            tokenInDecimals <= MAX_DECIMALS && tokenOutDecimals <= MAX_DECIMALS,
            OraclePriceAdjusterInvalidTokenDecimals(tokenInDecimals, tokenOutDecimals)
        );
        require(
            packedFeeds.length == FEED_LENGTH || packedFeeds.length == 2 * FEED_LENGTH,
            OraclePriceAdjusterInvalidFeedsLength(packedFeeds.length)
        );

        uint8 oracleDecimals = uint8(packedFeeds[0]) & DECIMALS_MASK;
        require(
            oracleDecimals <= MAX_DECIMALS,
            OraclePriceAdjusterInvalidOracleDecimals(oracleDecimals)
        );
        if (packedFeeds.length == 2 * FEED_LENGTH) {
            oracleDecimals = uint8(packedFeeds[FEED_LENGTH]) & DECIMALS_MASK;
            require(
                oracleDecimals <= MAX_DECIMALS,
                OraclePriceAdjusterInvalidOracleDecimals(oracleDecimals)
            );
        }

        uint8 decimalsConfig;
        if (tokenInDecimals >= tokenOutDecimals) {
            decimalsConfig = tokenInDecimals - tokenOutDecimals;
        } else {
            decimalsConfig = tokenOutDecimals - tokenInDecimals | SCALE_DOWN_FLAG;
        }

        ptr = ptr.push(marketPrice, 16).push(decimalsConfig).pushMem(packedFeeds);

        return ptr;
    }

    function parse(bytes calldata args) internal pure returns (uint128 marketPrice, uint8 decimalsConfig) {
        uint136 fixedArgs = args.at(0).asU136();
        marketPrice = uint128(fixedArgs >> 8);
        decimalsConfig = uint8(fixedArgs);
    }

    function scalePrice(uint256 price, uint8 decimalsConfig) internal pure returns (uint256) {
        uint256 scale = 10 ** (decimalsConfig & DECIMALS_MASK);
        return decimalsConfig & SCALE_DOWN_FLAG == 0 ? price * scale : price.ceilDiv(scale);
    }

    function readFeed(uint192 feed) internal view returns (uint256 feedPrice, bool isDenominator) {
        uint8 oracleDecimals = uint8(feed >> 184);
        isDenominator = oracleDecimals & DENOMINATOR_FLAG != 0;
        oracleDecimals &= DECIMALS_MASK;
        uint24 maxStaleness = uint24(feed >> 160);
        (, int256 answer, , uint256 updatedAt, ) = IPriceOracle(address(uint160(feed))).latestRoundData();

        require(answer > 0, OraclePriceAdjusterInvalidOraclePrice(answer));
        require(block.timestamp <= updatedAt + maxStaleness, OraclePriceAdjusterOraclePriceStale(block.timestamp, updatedAt, maxStaleness));

        feedPrice = uint256(answer) * 10 ** (MAX_DECIMALS - oracleDecimals);
    }

    function read(bytes calldata args) internal view returns (uint256 oraclePrice) {
        (uint256 feedPrice, bool isDenominator) = readFeed(args.at(FIXED_ARGS_LENGTH).asU192());
        oraclePrice = isDenominator ? uint256(1e36).ceilDiv(feedPrice) : feedPrice;

        if (args.length > FIXED_ARGS_LENGTH + FEED_LENGTH) {
            (feedPrice, isDenominator) = readFeed(args.at(FIXED_ARGS_LENGTH + FEED_LENGTH).asU192());
            oraclePrice = isDenominator
                ? oraclePrice.mulDiv(ONE, feedPrice, Math.Rounding.Ceil)
                : oraclePrice.mulDiv(feedPrice, ONE, Math.Rounding.Ceil);
        }
    }
}