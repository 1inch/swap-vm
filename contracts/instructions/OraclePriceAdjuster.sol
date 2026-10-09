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
/// @dev Arguments: [marketValue:160 | decimalsConfig:8 | packedFeed[1..2]]
///   decimalsConfig = [scaleNumerator:1 | decimalsExponent:7]
///   packedFeed = [maxStaleness:23 | isDenominator:1 | oracle:160]
///   scaleNumerator selects which ratio side is multiplied by 10 ** decimalsExponent
///   maxStaleness is in seconds; isDenominator places the raw oracle answer in the ratio denominator
///   marketValue is the reference raw tokenIn value of balanceOut
/// @dev If the oracle value rises above marketValue, the delta increases balanceIn and surcharge;
///   otherwise the delta consumes at most the existing surcharge
/// @dev Should be applied after balance-in surcharge discounts and before the swap curve
library OraclePriceAdjusterBalanceIn {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceIn;

    function sizeOf(uint160, uint8, uint8, uint8, bool, uint24, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + 3 + 20;
    }

    function sizeOf(uint160, uint8, uint8, uint8, bool, uint24, address, uint8, bool, uint24, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + 3 + 20 + 3 + 20;
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimals,
        bool isDenominator,
        uint24 maxStaleness,
        address oracle
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimals, isDenominator, maxStaleness, oracle)),
            marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimals, isDenominator, maxStaleness, oracle
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimals,
        bool isDenominator,
        uint24 maxStaleness,
        address oracle
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjuster.OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(maxStaleness <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStaleness));

        uint8 decimalsConfig = OraclePriceAdjuster.encodeDecimals(
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimals,
            isDenominator
        );

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(decimalsConfig);
        // [maxStaleness:23 | isDenominator:1]
        ptr = ptr.push((maxStaleness << 1) | (isDenominator ? 1 : 0), 3);
        ptr = ptr.push(oracle);
        ptrStart.patchLength(ptr);
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimalsIn,
        bool isDenominatorIn,
        uint24 maxStalenessIn,
        address oracleIn,
        uint8 oracleDecimalsOut,
        bool isDenominatorOut,
        uint24 maxStalenessOut,
        address oracleOut
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimalsIn, isDenominatorIn, maxStalenessIn, oracleIn, oracleDecimalsOut, isDenominatorOut, maxStalenessOut, oracleOut)),
            marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimalsIn, isDenominatorIn, maxStalenessIn, oracleIn, oracleDecimalsOut, isDenominatorOut, maxStalenessOut, oracleOut
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimalsIn,
        bool isDenominatorIn,
        uint24 maxStalenessIn,
        address oracleIn,
        uint8 oracleDecimalsOut,
        bool isDenominatorOut,
        uint24 maxStalenessOut,
        address oracleOut
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjuster.OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(maxStalenessIn <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStalenessIn));
        require(maxStalenessOut <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStalenessOut));

        uint8 decimalsConfig = OraclePriceAdjuster.encodeDecimals(
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimalsIn,
            isDenominatorIn,
            oracleDecimalsOut,
            isDenominatorOut
        );

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(decimalsConfig);
        // Each feed is [maxStaleness:23 | isDenominator:1 | oracle:160]
        ptr = ptr.push((maxStalenessIn << 1) | (isDenominatorIn ? 1 : 0), 3);
        ptr = ptr.push(oracleIn);
        ptr = ptr.push((maxStalenessOut << 1) | (isDenominatorOut ? 1 : 0), 3);
        ptr = ptr.push(oracleOut);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (
        uint160 marketValue,
        bool scaleNumerator,
        uint8 decimalsExponent
    ) {
        marketValue = args.at(0).asU160();
        scaleNumerator = args.at(20).asBool(0);
        decimalsExponent = args.at(20).asU8() & 0x7f;
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent) = parse(args);
        (uint256 numerator, uint256 denominator) = OraclePriceAdjuster.getPriceRatio(args[21:]);

        if (decimalsExponent != 0) {
            uint256 scale = 10 ** decimalsExponent;
            if (scaleNumerator) numerator *= scale;
            else denominator *= scale;
        }

        uint256 oracleValue = ctx.swap.balanceOut.mulDiv(
            numerator,
            denominator,
            Math.Rounding.Ceil
        );

        uint256 balanceDelta;
        if (oracleValue > marketValue) {
            balanceDelta = oracleValue - marketValue;
            ctx.swap.surcharge += balanceDelta;
            ctx.swap.balanceIn += balanceDelta;
        } else {
            balanceDelta = Math.min(
                marketValue - oracleValue,
                ctx.swap.surcharge
            );
            ctx.swap.surcharge -= balanceDelta;
            ctx.swap.balanceIn -= balanceDelta;
        }
    }
}

/// @notice OraclePriceAdjusterBalanceOut opcode, shifts an exact-buy auction by the market price movement
/// @dev Arguments: [marketValue:160 | decimalsConfig:8 | packedFeed[1..2]]
///   decimalsConfig = [scaleNumerator:1 | decimalsExponent:7]
///   packedFeed = [maxStaleness:23 | isDenominator:1 | oracle:160]
///   scaleNumerator selects which ratio side is multiplied by 10 ** decimalsExponent
///   maxStaleness is in seconds; isDenominator places the raw oracle answer in the ratio denominator
///   marketValue is the reference raw tokenOut value of balanceIn
/// @dev If the oracle value falls below marketValue, the delta decreases balanceOut and increases surcharge;
///   otherwise the delta consumes at most the existing surcharge
/// @dev Should be applied after balance-out surcharge discounts and before the swap curve
library OraclePriceAdjusterBalanceOut {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;
    using Math for uint256;

    Opcode constant opcode = Opcode.OraclePriceAdjusterBalanceOut;

    function sizeOf(uint160, uint8, uint8, uint8, bool, uint24, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + 3 + 20;
    }

    function sizeOf( uint160, uint8, uint8, uint8, bool, uint24, address, uint8, bool, uint24, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 20 + 1 + 3 + 20 + 3 + 20;
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimals,
        bool isDenominator,
        uint24 maxStaleness,
        address oracle
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimals, isDenominator, maxStaleness, oracle)),
            marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimals, isDenominator, maxStaleness, oracle
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimals,
        bool isDenominator,
        uint24 maxStaleness,
        address oracle
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjuster.OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(maxStaleness <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStaleness));

        uint8 decimalsConfig = OraclePriceAdjuster.encodeDecimals(
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimals,
            isDenominator
        );

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(decimalsConfig);
        // [maxStaleness:23 | isDenominator:1]
        ptr = ptr.push((maxStaleness << 1) | (isDenominator ? 1 : 0), 3);
        ptr = ptr.push(oracle);
        ptrStart.patchLength(ptr);
    }

    function build(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimalsIn,
        bool isDenominatorIn,
        uint24 maxStalenessIn,
        address oracleIn,
        uint8 oracleDecimalsOut,
        bool isDenominatorOut,
        uint24 maxStalenessOut,
        address oracleOut
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimalsIn, isDenominatorIn, maxStalenessIn, oracleIn, oracleDecimalsOut, isDenominatorOut, maxStalenessOut, oracleOut)),
            marketValue, tokenInDecimals, tokenOutDecimals, oracleDecimalsIn, isDenominatorIn, maxStalenessIn, oracleIn, oracleDecimalsOut, isDenominatorOut, maxStalenessOut, oracleOut
        ).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimalsIn,
        bool isDenominatorIn,
        uint24 maxStalenessIn,
        address oracleIn,
        uint8 oracleDecimalsOut,
        bool isDenominatorOut,
        uint24 maxStalenessOut,
        address oracleOut
    ) internal pure returns (MemoryPtr ptr) {
        require(marketValue != 0, OraclePriceAdjuster.OraclePriceAdjusterInvalidMarketValue(marketValue));
        require(maxStalenessIn <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStalenessIn));
        require(maxStalenessOut <= OraclePriceAdjuster.MAX_STALENESS, OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness(maxStalenessOut));

        uint8 decimalsConfig = OraclePriceAdjuster.encodeDecimals(
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimalsIn,
            isDenominatorIn,
            oracleDecimalsOut,
            isDenominatorOut
        );

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(marketValue, 20);
        ptr = ptr.push(decimalsConfig);
        // Each feed is [maxStaleness:23 | isDenominator:1 | oracle:160]
        ptr = ptr.push((maxStalenessIn << 1) | (isDenominatorIn ? 1 : 0), 3);
        ptr = ptr.push(oracleIn);
        ptr = ptr.push((maxStalenessOut << 1) | (isDenominatorOut ? 1 : 0), 3);
        ptr = ptr.push(oracleOut);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (
        uint160 marketValue,
        bool scaleNumerator,
        uint8 decimalsExponent
    ) {
        marketValue = args.at(0).asU160();
        scaleNumerator = args.at(20).asBool(0);
        decimalsExponent = args.at(20).asU8() & 0x7f;
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint160 marketValue, bool scaleNumerator, uint8 decimalsExponent) = parse(args);
        (uint256 numerator, uint256 denominator) = OraclePriceAdjuster.getPriceRatio(args[21:]);

        if (decimalsExponent != 0) {
            uint256 scale = 10 ** decimalsExponent;
            if (scaleNumerator) numerator *= scale;
            else denominator *= scale;
        }

        uint256 oracleValue = ctx.swap.balanceIn.mulDiv(
            denominator,
            numerator
        );

        uint256 balanceDelta;
        if (oracleValue < marketValue) {
            balanceDelta = Math.min(
                marketValue - oracleValue,
                ctx.swap.balanceOut
            );
            ctx.swap.surcharge += balanceDelta;
            ctx.swap.balanceOut -= balanceDelta;
        } else {
            balanceDelta = Math.min(
                oracleValue - marketValue,
                ctx.swap.surcharge
            );
            ctx.swap.surcharge -= balanceDelta;
            ctx.swap.balanceOut += balanceDelta;
        }
    }
}

library OraclePriceAdjuster {
    using CalldataParse for bytes;

    error OraclePriceAdjusterInvalidMarketValue(uint160 marketValue);
    error OraclePriceAdjusterInvalidOraclePrice(int256 oraclePrice);
    error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint24 maxStaleness);
    error OraclePriceAdjusterInvalidDecimalsExponent(uint16 decimalsExponent);
    error OraclePriceAdjusterInvalidMaxStaleness(uint24 maxStaleness);

    uint8 private constant MAX_DECIMALS_EXPONENT = 77;
    uint24 constant MAX_STALENESS = (1 << 23) - 1;

    uint256 private constant FEED_SIZE = 23;

    /// @dev Encodes the net decimal correction for a single feed
    function encodeDecimals(
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimals,
        bool isDenominator
    ) internal pure returns (uint8) {
        return encodeDecimals(
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimals,
            isDenominator,
            0,
            false
        );
    }

    /// @dev Encodes [scaleNumerator:1 | decimalsExponent:7] for one or two raw oracle answers
    function encodeDecimals(
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        uint8 oracleDecimalsIn,
        bool isDenominatorIn,
        uint8 oracleDecimalsOut,
        bool isDenominatorOut
    ) internal pure returns (uint8) {
        uint16 numeratorDecimals = tokenInDecimals;
        uint16 denominatorDecimals = tokenOutDecimals;

        // A denominator answer contributes its decimal correction to the numerator, and vice versa
        if (isDenominatorIn) numeratorDecimals += oracleDecimalsIn;
        else denominatorDecimals += oracleDecimalsIn;

        if (isDenominatorOut) numeratorDecimals += oracleDecimalsOut;
        else denominatorDecimals += oracleDecimalsOut;

        bool scaleNumerator = numeratorDecimals >= denominatorDecimals;
        uint16 decimalsExponent = scaleNumerator
            ? numeratorDecimals - denominatorDecimals
            : denominatorDecimals - numeratorDecimals;

        require(decimalsExponent <= MAX_DECIMALS_EXPONENT, OraclePriceAdjusterInvalidDecimalsExponent(decimalsExponent));
        return InstructionBuilder.encodeBool(scaleNumerator, 0) | uint8(decimalsExponent);
    }

    /// @dev Returns the unscaled oracle ratio without intermediate division
    function getPriceRatio(bytes calldata feeds) internal view returns (uint256 numerator, uint256 denominator) {
        uint184 packedFeedA = feeds.at(0).asU184();
        bool isDenominatorA;
        (numerator, isDenominatorA) = getFeedPrice(packedFeedA);

        denominator = 1;
        if (feeds.length != FEED_SIZE) {
            (uint256 feedPriceB, bool isDenominatorB) = getFeedPrice(feeds.at(FEED_SIZE).asU184());
            // Same-side feeds multiply; opposite-side feeds divide
            if (isDenominatorA == isDenominatorB) numerator *= feedPriceB;
            else denominator = feedPriceB;
        }

        if (isDenominatorA) {
            (numerator, denominator) = (denominator, numerator);
        }
    }

    /// @dev Decodes [maxStaleness:23 | isDenominator:1 | oracle:160] and reads the raw answer
    function getFeedPrice(uint184 packedFeed) internal view returns (uint256 feedPrice, bool isDenominator) {
        uint24 config = uint24(packedFeed >> 160);
        isDenominator = config & 1 != 0;
        uint24 maxStaleness = config >> 1;
        address oracle = address(uint160(packedFeed));

        (, int256 answer, , uint256 updatedAt, ) = IPriceOracle(oracle).latestRoundData();

        require(answer > 0, OraclePriceAdjusterInvalidOraclePrice(answer));
        require(block.timestamp <= updatedAt + maxStaleness, OraclePriceAdjusterOraclePriceStale(block.timestamp, updatedAt, maxStaleness));

        feedPrice = uint256(answer);
    }
}