// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";
import { CalldataCut } from "@1inch/solidity-utils/contracts/libraries/CalldataCut.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

error OraclePriceAdjusterInvalidMarketValue(uint160 marketValue);
error OraclePriceAdjusterInvalidMaxStaleness(uint24 maxStaleness);
error OraclePriceAdjusterInvalidOraclePrice(int256 oraclePrice);
error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint24 maxStaleness);
error OraclePriceAdjusterInvalidDecimalsExponent(uint256 decimalsExponent);
error OraclePriceAdjusterInvalidFeedCount(uint256 count);

uint256 constant MAX_DECIMALS_EXPONENT = 77;
uint256 constant FEED_SIZE = 23;

struct Feed {
    uint8 oracleDecimals;
    bool isDenominator;
    uint24 maxStaleness;
    address oracle;
}

/// @notice OraclePriceAdjusterBalanceIn opcode, shifts an exact-sell auction by the market price movement
/// @dev Encoding: [uint160 marketValue, bytes1 decimalsConfig, bytes23 packedFeed[1..2]]
///   decimalsConfig = [bit1 scaleNumerator, uint7 decimalsExponent]
///   packedFeed = [uint23 maxStaleness, bit1 isDenominator, address oracle]
///   scaleNumerator selects which ratio side is multiplied by 10 ** decimalsExponent
///   maxStaleness is in seconds; isDenominator places the raw oracle answer in the ratio denominator
///   marketValue is the reference raw token in value of balance out
/// @dev If the oracle value rises above `marketValue`, the delta increases balance in and surcharge;
///   otherwise the delta consumes at most the existing surcharge
/// @dev Should be applied after balance in surcharge applied and before InvalidateTokenOut opcode
library OraclePriceAdjusterBalanceIn {
    using CalldataParse for bytes;
    using CalldataCut for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceIn;

    function sizeOf(uint160, uint8, uint8, Feed[] memory feeds) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + feeds.length * FEED_SIZE;
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        Feed[] memory feeds
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, feeds)),
            marketValue, tokenInDecimals, tokenOutDecimals, feeds
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        Feed[] memory feeds
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(feeds.length == 1 || feeds.length == 2, OraclePriceAdjusterInvalidFeedCount(feeds.length));

        int256 shift = int256(uint256(tokenInDecimals)) - int256(uint256(tokenOutDecimals));
        for (uint256 i; i < feeds.length; i++) {
            uint8 oracleDecimals = feeds[i].oracleDecimals;
            shift += feeds[i].isDenominator ? int256(uint256(oracleDecimals)) : -int256(uint256(oracleDecimals));
        }

        bool scaleNumerator = shift >= 0;
        uint256 decimalsExponent = uint256(scaleNumerator ? shift : -shift);
        require(decimalsExponent <= MAX_DECIMALS_EXPONENT, OraclePriceAdjusterInvalidDecimalsExponent(decimalsExponent));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(InstructionBuilder.encodeBool(scaleNumerator, 0) | uint8(decimalsExponent));
        for (uint256 i; i < feeds.length; i++) {
            require(feeds[i].maxStaleness & 0x800000 == 0, OraclePriceAdjusterInvalidMaxStaleness(feeds[i].maxStaleness));
            ptr = ptr.push((uint24(feeds[i].maxStaleness) << 1) | InstructionBuilder.encodeBool(feeds[i].isDenominator, 7), 3);
            ptr = ptr.push(feeds[i].oracle);
        }
        ptrStart.patchLength(ptr);
    }

    /// @dev Decodes [uint160 marketValue, bytes1 decimalsConfig]; the tail is packedFeed[1..2]
    function parse(bytes calldata args) internal pure returns (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) {
        marketValue = args.at(0).asU160();
        scaleNumerator = args.at(20).asBool(0);
        decimalsExponent = args.at(20).asU8() & 0x7f;
        feeds = args.slice(21);
    }

    /// @dev Decodes [uint23 maxStaleness, bit1 isDenominator, address oracle]
    function parseFeed(bytes calldata feed) internal pure returns (bool isDenominator, uint24 maxStaleness, address oracle) {
        isDenominator = feed.at(0).asBool(23);
        maxStaleness = feed.at(0).asU24() >> 1;
        oracle = feed.at(3).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) = parse(args);

        uint256 numerator = 1;
        uint256 denominator = 1;
        while (true) {
            (bool isDenominator, uint24 maxStaleness, address oracle) = parseFeed(feeds);
            (, int256 answer, , uint256 updatedAt, ) = IPriceOracle(oracle).latestRoundData();

            require(answer > 0, OraclePriceAdjusterInvalidOraclePrice(answer));
            require(block.timestamp - updatedAt <= maxStaleness, OraclePriceAdjusterOraclePriceStale(block.timestamp, updatedAt, maxStaleness));

            if (isDenominator) denominator *= uint256(answer);
            else numerator *= uint256(answer);

            if (feeds.length == FEED_SIZE) break;
            feeds = feeds.slice(FEED_SIZE);
        }

        uint256 scale = 10 ** uint256(decimalsExponent);
        if (scaleNumerator) numerator *= scale;
        else denominator *= scale;

        uint256 oracleValue = ctx.swap.balanceOut.mulDiv(numerator, denominator, Math.Rounding.Ceil);

        uint256 balanceDelta;
        if (oracleValue > marketValue) {
            balanceDelta = oracleValue - marketValue;
            ctx.swap.surcharge += balanceDelta;
            ctx.swap.balanceIn += balanceDelta;
        } else {
            balanceDelta = Math.min(marketValue - oracleValue, ctx.swap.surcharge);
            ctx.swap.surcharge -= balanceDelta;
            ctx.swap.balanceIn -= balanceDelta;
        }
    }
}

/// @notice OraclePriceAdjusterBalanceOut opcode, shifts an exact-buy auction by the market price movement
/// @dev Encoding: [uint160 marketValue, bytes1 decimalsConfig, bytes23 packedFeed[1..2]]
///   decimalsConfig = [bit1 scaleNumerator, uint7 decimalsExponent]
///   packedFeed = [uint23 maxStaleness, bit1 isDenominator, address oracle]
///   scaleNumerator selects which ratio side is multiplied by 10 ** decimalsExponent
///   maxStaleness is in seconds; isDenominator places the raw oracle answer in the ratio denominator
///   marketValue is the reference raw token out value of balance in
/// @dev If the oracle value falls below `marketValue`, the delta decreases balance out and increases surcharge;
///   otherwise the delta consumes at most the existing surcharge
/// @dev Should be applied after balance out surcharge applied and before InvalidateTokenIn opcode
library OraclePriceAdjusterBalanceOut {
    using CalldataParse for bytes;
    using CalldataCut for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceOut;

    function sizeOf(uint160, uint8, uint8, Feed[] memory feeds) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + feeds.length * FEED_SIZE;
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        Feed[] memory feeds
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, feeds)),
            marketValue, tokenInDecimals, tokenOutDecimals, feeds
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        Feed[] memory feeds
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(feeds.length == 1 || feeds.length == 2, OraclePriceAdjusterInvalidFeedCount(feeds.length));

        int256 shift = int256(uint256(tokenInDecimals)) - int256(uint256(tokenOutDecimals));
        for (uint256 i; i < feeds.length; i++) {
            uint8 oracleDecimals = feeds[i].oracleDecimals;
            shift += feeds[i].isDenominator ? int256(uint256(oracleDecimals)) : -int256(uint256(oracleDecimals));
        }

        bool scaleNumerator = shift >= 0;
        uint256 decimalsExponent = uint256(scaleNumerator ? shift : -shift);
        require(decimalsExponent <= MAX_DECIMALS_EXPONENT, OraclePriceAdjusterInvalidDecimalsExponent(decimalsExponent));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(InstructionBuilder.encodeBool(scaleNumerator, 0) | uint8(decimalsExponent));
        for (uint256 i; i < feeds.length; i++) {
            require(feeds[i].maxStaleness & 0x800000 == 0, OraclePriceAdjusterInvalidMaxStaleness(feeds[i].maxStaleness));
            ptr = ptr.push((uint24(feeds[i].maxStaleness) << 1) | InstructionBuilder.encodeBool(feeds[i].isDenominator, 7), 3);
            ptr = ptr.push(feeds[i].oracle);
        }
        ptrStart.patchLength(ptr);
    }

    /// @dev Decodes [uint160 marketValue, bytes1 decimalsConfig]; the tail is packedFeed[1..2]
    function parse(bytes calldata args) internal pure returns (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) {
        marketValue = args.at(0).asU160();
        scaleNumerator = args.at(20).asBool(0);
        decimalsExponent = args.at(20).asU8() & 0x7f;
        feeds = args.slice(21);
    }

    /// @dev Decodes [uint23 maxStaleness, bit1 isDenominator, address oracle]
    function parseFeed(bytes calldata feed) internal pure returns (bool isDenominator, uint24 maxStaleness, address oracle) {
        isDenominator = feed.at(0).asBool(23);
        maxStaleness = feed.at(0).asU24() >> 1;
        oracle = feed.at(3).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) = parse(args);

        uint256 numerator = 1;
        uint256 denominator = 1;
        while (true) {
            (bool isDenominator, uint24 maxStaleness, address oracle) = parseFeed(feeds);
            (, int256 answer, , uint256 updatedAt, ) = IPriceOracle(oracle).latestRoundData();

            require(answer > 0, OraclePriceAdjusterInvalidOraclePrice(answer));
            require(block.timestamp - updatedAt <= maxStaleness, OraclePriceAdjusterOraclePriceStale(block.timestamp, updatedAt, maxStaleness));

            if (isDenominator) denominator *= uint256(answer);
            else numerator *= uint256(answer);

            if (feeds.length == FEED_SIZE) break;
            feeds = feeds.slice(FEED_SIZE);
        }

        uint256 scale = 10 ** uint256(decimalsExponent);
        if (scaleNumerator) numerator *= scale;
        else denominator *= scale;

        uint256 oracleValue = ctx.swap.balanceIn.mulDiv(denominator, numerator);

        if (oracleValue < marketValue) {
            uint256 balanceDelta = Math.min(marketValue - oracleValue, ctx.swap.balanceOut);
            ctx.swap.surcharge += balanceDelta;
            ctx.swap.balanceOut -= balanceDelta;
        } else {
            uint256 balanceDelta = Math.min(oracleValue - marketValue, ctx.swap.surcharge);
            ctx.swap.surcharge -= balanceDelta;
            ctx.swap.balanceOut += balanceDelta;
        }
    }
}
