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

/// @notice OraclePriceAdjuster opcode, shifts an auction by the market price movement
/// @dev Encoding: [bool adjustIn, uint160 marketValue, bytes1 decimalsConfig, bytes23 packedFeed[1..2]]
///   decimalsConfig = [bit1 scaleNumerator, uint7 decimalsExponent]
///   packedFeed = [uint23 maxStaleness, bit1 isDenominator, address oracle]
///   scaleNumerator selects which ratio side is multiplied by 10 ** decimalsExponent
///   maxStaleness is in seconds; isDenominator places the raw oracle answer in the ratio denominator
/// @dev The `marketValue` is the reference token in value of balance out for `adjustIn = true` or
///   the reference token out value of balance in for `adjustIn = false`
/// @dev Should be applied after surcharge applied and before InvalidateTokenOut for `adjustIn = true`
///   or InvalidateTokenIn for `adjustIn = false`
library OraclePriceAdjuster {
    using CalldataParse for bytes;
    using CalldataCut for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    error OraclePriceAdjusterInvalidMarketValue(uint160 marketValue);
    error OraclePriceAdjusterInvalidMaxStaleness(uint24 maxStaleness);
    error OraclePriceAdjusterInvalidOraclePrice(int256 oraclePrice);
    error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint24 maxStaleness);
    error OraclePriceAdjusterInvalidDecimalsExponent(uint256 decimalsExponent);
    error OraclePriceAdjusterInvalidFeedCount(uint256 count);

    Opcode constant opcode = Opcode.OraclePriceAdjuster;

    uint256 constant MAX_DECIMALS_EXPONENT = 77;
    uint256 constant FEED_SIZE = 23;

    struct Feed {
        uint8 oracleDecimals;
        bool isDenominator;
        uint24 maxStaleness;
        address oracle;
    }

    function sizeOf(uint256 feedsLen) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + 20 + 1 + feedsLen * FEED_SIZE;
    }

    function build(
        bool adjustIn,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        Feed[] memory feeds
    ) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(feeds.length)), adjustIn, marketValue, tokenInDecimals, tokenOutDecimals, feeds).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool adjustIn,
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
        ptr = ptr.push(InstructionBuilder.encodeBool(adjustIn, 0)).push(marketValue, 20);
        ptr = ptr.push(InstructionBuilder.encodeBool(scaleNumerator, 0) | uint8(decimalsExponent));
        for (uint256 i; i < feeds.length; i++) {
            require(feeds[i].maxStaleness & 0x800000 == 0, OraclePriceAdjusterInvalidMaxStaleness(feeds[i].maxStaleness));
            ptr = ptr.push((uint24(feeds[i].maxStaleness) << 1) | InstructionBuilder.encodeBool(feeds[i].isDenominator, 7), 3);
            ptr = ptr.push(feeds[i].oracle);
        }
        ptrStart.patchLength(ptr);
    }

    /// @dev Decodes [bool adjustIn, uint160 marketValue, bytes1 decimalsConfig]; the tail is packedFeed[1..2]
    function parse(
        bytes calldata args
    ) internal pure returns (bool adjustIn, uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) {
        adjustIn = args.at(0).asBool(0);
        marketValue = args.at(1).asU160();
        scaleNumerator = args.at(21).asBool(0);
        decimalsExponent = args.at(21).asU8() & 0x7f;
        feeds = args.slice(22);
    }

    /// @dev Decodes [uint23 maxStaleness, bit1 isDenominator, address oracle]
    function parseFeed(bytes calldata feed) internal pure returns (bool isDenominator, uint24 maxStaleness, address oracle) {
        isDenominator = feed.at(0).asBool(23);
        maxStaleness = feed.at(0).asU24() >> 1;
        oracle = feed.at(3).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (bool adjustIn, uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent, bytes calldata feeds) = parse(args);

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

        if (adjustIn) {
            uint256 oracleValue = ctx.swap.balanceOut.mulDiv(numerator, denominator, Math.Rounding.Ceil);

            uint256 balanceDelta;
            if (oracleValue > marketValue) {
                unchecked { balanceDelta = oracleValue - marketValue; }
                ctx.swap.surcharge += balanceDelta;
                ctx.swap.balanceIn += balanceDelta;
            } else {
                unchecked { balanceDelta = Math.min(marketValue - oracleValue, ctx.swap.surcharge); }
                ctx.swap.surcharge -= balanceDelta;
                ctx.swap.balanceIn -= balanceDelta;
            }
        } else {
            uint256 oracleValue = ctx.swap.balanceIn.mulDiv(denominator, numerator);

            uint256 balanceDelta;
            if (oracleValue < marketValue) {
                unchecked { balanceDelta = Math.min(marketValue - oracleValue, ctx.swap.balanceOut); }
                ctx.swap.surcharge += balanceDelta;
                ctx.swap.balanceOut -= balanceDelta;
            } else {
                unchecked { balanceDelta = Math.min(oracleValue - marketValue, ctx.swap.surcharge); }
                ctx.swap.surcharge -= balanceDelta;
                ctx.swap.balanceOut += balanceDelta;
            }
        }
    }
}
