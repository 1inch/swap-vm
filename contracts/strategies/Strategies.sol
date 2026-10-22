// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { StaticBalances } from "../instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../instructions/LimitSwap.sol";
import { XYCConcentrateSwap } from "../instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../instructions/FeeFlat.sol";
import { Decay } from "../instructions/Decay.sol";
import { FeeProtocol, FeeProtocolSurplus } from "../instructions/FeeProtocol.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut } from "../instructions/Invalidators.sol";
import { Jump } from "../instructions/Jumps.sol";
import { PrivateOrder, WhitelistCoequal } from "../instructions/Whitelist.sol";
import { PiecewiseLinearSurcharge } from "../instructions/PiecewiseLinearSurcharge.sol";
import { OraclePriceAdjuster } from "../instructions/OraclePriceAdjuster.sol";
import { BaseFeeAdjuster } from "../instructions/BaseFeeAdjuster.sol";
import { FillGridAdjuster } from "../instructions/FillGridAdjuster.sol";
import {
    OnlyTakerTokenBalanceNonZero,
    OnlyTakerTokenBalanceGte,
    OnlyTakerTokenSupplyShareGte,
    OnlyTxOriginTokenBalanceNonZero
} from "../instructions/TokenValidators.sol";
import { Deadline, Salt } from "../instructions/Controls.sol";
import { ValidateSeriesEpoch } from "../instructions/SeriesEpochManager.sol";

/// @dev Library for on-chain orders validation
///   Prefixes does not impact amounts calculation, so arbitrary allowed
///   Proposed strategies holds some invariants such as maker min/max swap rate
library Strategies {
    using SafeCast for uint256;
    using CalldataParse for bytes;

    error PrefixInvalidLength(uint256 length, uint256 expected);
    error PrefixUnregistered(uint8 opcode);
    error OrderInconsistent();

    struct LimitOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        bool sell;
    }

    struct XYCConcentrateOrder {
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint24 feeBps;
        uint16 decayPeriod;
    }

    struct FusionOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
        bool sell;
        bool allowPartialFills;
        bool allowMultipleFills;
        uint32 nonce;
        uint40 auctionStartTime;
        uint16[] auctionDurations;
        uint24[] auctionScales;
        uint24[] fillBps;
        uint24[] adjustBps;
        uint160 oracleMarketValue;
        uint8 tokenInDecimals;
        uint8 tokenOutDecimals;
        OraclePriceAdjuster.Feed[] oracleFeeds;
        uint64 baseGasPrice;
        uint96 ethPrice;
        uint24 gasAmount;
        address[] whitelistResolvers;
        address accessToken;
        FeeProtocol.ReceiverConfig[] feeReceivers;
        uint24 whitelistFeeDiscount;
        uint256 surplusEstimation;
    }

    uint256 private constant _prefixBitmap =
        (1 << uint256(OnlyTakerTokenBalanceNonZero.opcode)) |
        (1 << uint256(OnlyTakerTokenBalanceGte.opcode)) |
        (1 << uint256(OnlyTakerTokenSupplyShareGte.opcode)) |
        (1 << uint256(OnlyTxOriginTokenBalanceNonZero.opcode)) |
        (1 << uint256(PrivateOrder.opcode)) |
        (1 << uint256(InvalidateBit.opcode)) |
        (1 << uint256(Deadline.opcode)) |
        (1 << uint256(Salt.opcode)) |
        (1 << uint256(ValidateSeriesEpoch.opcode));

    /// @notice Prefixes are validation-only opcodes which do not change registers
    ///   Wrongly built prefix instructions do not affect strategy calculations,
    ///   so checking only opcode is in prefix bitmap and length consistency is enough
    function _checkPrefix(bytes[] calldata instructions) private pure returns (uint256 prefixSize) {
        for (uint256 i; i < instructions.length; i++) {
            bytes calldata instruction = instructions[i];
            uint8 opcode = instruction.at(0).asU8();
            uint256 length = 2 + instruction.at(1).asU8();

            require(instruction.length == length, PrefixInvalidLength(instruction.length, length));
            require(_prefixBitmap & (1 << opcode) != 0, PrefixUnregistered(opcode));

            prefixSize += instruction.length;
        }
    }

    /// @notice Limit order: `StaticBalances` + `InvalidateToken Out/In` + `LimitSwap`, the maker
    ///   swaps at the fixed rate `balanceA / balanceB` in one direction, partial fills bounded by the balances in total
    function buildLimitOrder(
        bytes[] calldata prefix,
        LimitOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf() +
            (args.sell ? InvalidateTokenOut.sizeOf() : InvalidateTokenIn.sizeOf()) +
            LimitSwap.sizeOf()
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        if (args.sell) ptr = InvalidateTokenOut.build(ptr);
        else ptr = InvalidateTokenIn.build(ptr);
        ptr = LimitSwap.build(ptr, args.direction);

        return ptr.resolve();
    }

    /// @notice Concentrated liquidity AMM order: `FeeFlatIn` + [`Decay`] + `XYCConcentrateSwap`, a constant-product
    ///   curve over the maker's Aqua reserves with liquidity concentrated in the price range, both directions
    /// @dev Balances are Aqua supplied
    function buildXYCConcentrateOrder(
        bytes[] calldata prefix,
        XYCConcentrateOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            FeeFlatIn.sizeOf() +
            (args.decayPeriod != 0 ? Decay.sizeOf() : 0) +
            XYCConcentrateSwap.sizeOf()
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = FeeFlatIn.build(ptr, args.feeBps);
        if (args.decayPeriod != 0) ptr = Decay.build(ptr, args.decayPeriod);
        ptr = XYCConcentrateSwap.build(ptr, args.sqrtPriceMin, args.sqrtPriceMax);

        return ptr.resolve();
    }

    /// @notice Fusion order: the maker sells `balanceOut` for at least `balanceIn` or buys `balanceIn` for at most
    ///   `balanceOut` in one direction, with a Dutch auction price and optional resolver benefits
    /// @dev Every feature is optional, in program order after `prefix` and `StaticBalances`:
    ///   - Whitelist, `WhitelistCoequal`: whitelisted resolvers skip the access token and receive the fee discount,
    ///     while public takers use the public branch. Empty `whitelistResolvers` disables
    ///   - Access token, `OnlyTakerTokenBalanceNonZero`: the public taker holds `accessToken`. `address(0)` disables
    ///   - Fees, `FeeProtocol`: `feeReceivers` charged to the taker, whitelisted resolvers get `whitelistFeeDiscount`
    ///     (`1e7` is 100%) off every receiver's flat `feeBps`, the surplus shares stay. Empty `feeReceivers`
    ///     disables, the discount requires the whitelist
    ///   - Surplus fee, `FeeProtocolSurplus`: receivers with `surplusBps` take their share of receive above the
    ///     sell estimation or spend below the buy estimation, scaled to the filled part of the order. The estimation
    ///     may not cross the limit balance. No surplus config disables and `surplusEstimation` is ignored
    ///   - Auction, `PiecewiseLinearSurcharge`: `auctionScales[i]` improves the maker price at point `i`,
    ///     `2 ** 24` is +100%, `auctionDurations[i]` seconds separate points `i` and `i + 1` starting at
    ///     `auctionStartTime`. Empty `auctionScales` disables
    ///   - Oracle adjustment, `OraclePriceAdjuster`: shifts the maker price by the market move since the order was
    ///     priced. Empty `oracleFeeds` disables, `oracleMarketValue` stays zero
    ///   - Gas bump, `BaseFeeAdjuster`: discounts the maker price by the base-fee cost, capped by the surcharge.
    ///     `gasAmount == 0` disables, requires the auction
    ///   - Fills: `allowPartialFills` picks `LimitSwap` over `LimitSwapFullAmount` (fill-or-kill),
    ///     `allowMultipleFills` caps cumulative output for sell orders or input for buy orders; otherwise
    ///     `InvalidateBit` with the maker-scoped `nonce` lets the order fill once
    ///   - Fill grid, `FillGridAdjuster`: `fillBps` and `adjustBps` redistribute the final auction surcharge by
    ///     fill percentage. Empty arrays disable
    ///   Time fields with `Time.RELATIVE_TIME_FLAG` set count from the order announcement
    function buildFusionOrder(
        bytes[] calldata prefix,
        FusionOrder calldata args
    ) internal pure returns (bytes memory) {
        bool hasWhitelist = args.whitelistResolvers.length > 0;
        bool hasFees = args.feeReceivers.length > 0;
        bool hasGate = args.accessToken != address(0);
        bool hasAuction = args.auctionScales.length > 0;
        bool hasFillGrid = args.fillBps.length > 0 || args.adjustBps.length > 0;
        bool hasOracle = args.oracleFeeds.length > 0;
        bool hasGasBump = args.gasAmount != 0;
        bool hasSurplus;
        for (uint256 i; i < args.feeReceivers.length; i++) hasSurplus = hasSurplus || args.feeReceivers[i].surplusBps > 0;

        // The whitelist discount needs the whitelist and is at most the whole flat fee
        require(hasWhitelist || args.whitelistFeeDiscount == 0, OrderInconsistent());
        require(args.whitelistFeeDiscount <= FeeProtocol.BPS, OrderInconsistent());
        // Oracle market value goes with the feeds
        require(hasOracle || args.oracleMarketValue == 0, OrderInconsistent());
        // Gas bump consumes the auction surcharge
        require(hasAuction || !hasGasBump, OrderInconsistent());
        // The limit price itself never carries a surplus fee
        uint256 balanceIn = args.direction ? args.balanceA : args.balanceB;
        uint256 balanceOut = args.direction ? args.balanceB : args.balanceA;
        require(
            !hasSurplus || (args.sell ? args.surplusEstimation >= balanceIn : args.surplusEstimation <= balanceOut),
            OrderInconsistent()
        );

        // Whitelisted resolvers pay the same receivers with the discount off the flat fee
        FeeProtocol.ProviderConfig[] memory noProviders;
        FeeProtocol.ReceiverConfig[] memory whitelistedReceivers = new FeeProtocol.ReceiverConfig[](args.feeReceivers.length);
        for (uint256 i; i < whitelistedReceivers.length; i++) {
            whitelistedReceivers[i] = args.feeReceivers[i];
            whitelistedReceivers[i].feeBps = uint24(args.feeReceivers[i].feeBps * (FeeProtocol.BPS - args.whitelistFeeDiscount) / FeeProtocol.BPS);
        }

        MemoryPtr ptrStart = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf() +
            (hasWhitelist ? WhitelistCoequal.sizeOf(args.whitelistResolvers.length) : 0) +
            (hasGate ? OnlyTakerTokenBalanceNonZero.sizeOf() : 0) +
            (hasFees ? FeeProtocol.sizeOf(args.feeReceivers.length, noProviders.length) : 0) +
            (hasWhitelist ? Jump.sizeOf() : 0) +
            (hasWhitelist && hasFees ? FeeProtocol.sizeOf(whitelistedReceivers.length, noProviders.length) : 0) +
            (hasSurplus ? FeeProtocolSurplus.sizeOf() : 0) +
            (hasAuction ? PiecewiseLinearSurcharge.sizeOf(args.auctionDurations.length, args.auctionScales.length) : 0) +
            (hasOracle ? OraclePriceAdjuster.sizeOf(args.oracleFeeds.length) : 0) +
            (hasGasBump ? BaseFeeAdjuster.sizeOf() : 0) +
            (args.allowMultipleFills ? (args.sell ? InvalidateTokenOut.sizeOf() : InvalidateTokenIn.sizeOf()) : InvalidateBit.sizeOf()) +
            (hasFillGrid ? FillGridAdjuster.sizeOf(args.fillBps.length, args.adjustBps.length) : 0) +
            (args.allowPartialFills ? LimitSwap.sizeOf() : LimitSwapFullAmount.sizeOf())
        );

        MemoryPtr ptr = ptrStart;
        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);

        // The whitelist target is patched once the public-only sections it skips are written
        MemoryPtr ptrWhitelist = ptr;
        if (hasWhitelist) ptr = WhitelistCoequal.build(ptr, 0, args.whitelistResolvers);

        // Public branch, ends with the jump over the whitelisted one
        if (hasGate) ptr = OnlyTakerTokenBalanceNonZero.build(ptr, args.accessToken);
        if (hasFees) ptr = FeeProtocol.build(ptr, args.sell, args.feeReceivers, noProviders);
        MemoryPtr ptrJump = ptr;
        if (hasWhitelist) ptr = Jump.build(ptr, 0);

        // Whitelisted branch, the jump target is patched once the whitelisted fees it skips are written
        if (hasWhitelist) WhitelistCoequal.patchNextPC(ptrWhitelist, ptr.sub(ptrStart).toUint16());
        if (hasWhitelist && hasFees) ptr = FeeProtocol.build(ptr, args.sell, whitelistedReceivers, noProviders);
        if (hasWhitelist) Jump.patchNextPC(ptrJump, ptr.sub(ptrStart).toUint16());

        if (hasSurplus) ptr = FeeProtocolSurplus.build(ptr, args.sell, args.surplusEstimation);
        if (hasAuction) ptr = PiecewiseLinearSurcharge.build(ptr, args.sell, args.auctionStartTime, args.auctionDurations, args.auctionScales);
        if (hasOracle) ptr = OraclePriceAdjuster.build(ptr, args.sell, args.oracleMarketValue, args.tokenInDecimals, args.tokenOutDecimals, args.oracleFeeds);
        if (hasGasBump) ptr = BaseFeeAdjuster.build(ptr, args.sell, args.baseGasPrice, args.ethPrice, args.gasAmount);
        if (args.allowMultipleFills && args.sell) ptr = InvalidateTokenOut.build(ptr);
        else if (args.allowMultipleFills) ptr = InvalidateTokenIn.build(ptr);
        else ptr = InvalidateBit.build(ptr, args.nonce);
        if (hasFillGrid) ptr = FillGridAdjuster.build(ptr, args.sell, args.fillBps, args.adjustBps);
        if (args.allowPartialFills) ptr = LimitSwap.build(ptr, args.direction);
        else ptr = LimitSwapFullAmount.build(ptr, args.direction);

        return ptr.resolve();
    }
}
