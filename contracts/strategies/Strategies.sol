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
import { InvalidateBit, InvalidateTokenBuy, InvalidateTokenSell } from "../instructions/Invalidators.sol";
import { Jump } from "../instructions/Jumps.sol";
import { PrivateOrder, WhitelistCoequal, WhitelistSequential } from "../instructions/Whitelist.sol";
import { PiecewiseLinearSurchargeSell } from "../instructions/PiecewiseLinearSurcharge.sol";
import { Feed, OraclePriceAdjusterSell } from "../instructions/OraclePriceAdjuster.sol";
import { BaseFeeAdjusterSell } from "../instructions/BaseFeeAdjuster.sol";
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
        bool allowPartialFills;
        bool allowMultipleFills;
        uint32 nonce;
        uint40 auctionStartTime;
        uint16[] auctionDurations;
        uint24[] auctionScales;
        uint160 oracleMarketValue;
        uint8 tokenInDecimals;
        uint8 tokenOutDecimals;
        Feed[] oracleFeeds;
        uint64 baseGasPrice;
        uint96 ethPrice;
        uint24 gasAmount;
        bool whitelistCoequal;
        uint40 whitelistStartTime;
        address[] whitelistResolvers;
        uint16[] whitelistDelays;
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

    /// @notice Limit order: `StaticBalances` + `InvalidateTokenSell` / `InvalidateTokenBuy` + `LimitSwap`, the maker
    ///   swaps at the fixed rate `balanceA / balanceB` in one direction, partial fills bounded by the balances in total
    function buildLimitOrder(
        bytes[] calldata prefix,
        LimitOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            (args.sell ? InvalidateTokenSell.sizeOf() : InvalidateTokenBuy.sizeOf()) +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        if (args.sell) ptr = InvalidateTokenSell.build(ptr);
        else ptr = InvalidateTokenBuy.build(ptr);
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
            FeeFlatIn.sizeOf(args.feeBps) +
            (args.decayPeriod != 0 ? Decay.sizeOf(args.decayPeriod) : 0) +
            XYCConcentrateSwap.sizeOf(args.sqrtPriceMin, args.sqrtPriceMax)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = FeeFlatIn.build(ptr, args.feeBps);
        if (args.decayPeriod != 0) ptr = Decay.build(ptr, args.decayPeriod);
        ptr = XYCConcentrateSwap.build(ptr, args.sqrtPriceMin, args.sqrtPriceMax);

        return ptr.resolve();
    }

    /// @notice Fusion order: the maker sells `balanceOut` for at least `balanceIn` in one direction, the price
    ///   starts above the limit and decays along a Dutch auction, whitelisted resolvers fill first and the public
    ///   fills after the whitelist period, fees are charged to the taker in token in on top of the maker's amount
    /// @dev Every feature is optional, in program order after `prefix` and `StaticBalances`:
    ///   - Whitelist, `WhitelistSequential`: nobody fills before `whitelistStartTime`, `whitelistResolvers[0]`
    ///     fills from there, each next one `whitelistDelays[i]` seconds later, everybody after the last delay.
    ///     `whitelistCoequal` switches to `WhitelistCoequal`: every resolver and the public fill from the start,
    ///     `whitelistStartTime` and `whitelistDelays` stay zero. Either way whitelisted resolvers skip the access
    ///     token and the public fees. Empty `whitelistResolvers` disables, the order is public from the start
    ///   - Access token, `OnlyTakerTokenBalanceNonZero`: the public taker holds `accessToken`. `address(0)` disables
    ///   - Fees, `FeeProtocol`: `feeReceivers` charged to the taker, whitelisted resolvers get `whitelistFeeDiscount`
    ///     (`1e7` is 100%) off every receiver's flat `feeBps`, the surplus shares stay. Empty `feeReceivers`
    ///     disables, the discount requires the whitelist
    ///   - Surplus fee, `FeeProtocolSurplus`: receivers with `surplusBps` take their share of what the taker pays
    ///     above `surplusEstimation`, scaled to the filled part of the order,
    ///     `surplusEstimation >= balanceIn` so the limit price never carries a surplus fee. No surplus config
    ///     disables and `surplusEstimation` is ignored
    ///   - Auction, `PiecewiseLinearSurchargeSell`: `auctionScales[i]` surcharges the maker's receive at
    ///     point `i`, `2 ** 24` is +100%, `auctionDurations[i]` seconds separate points `i` and `i + 1` starting
    ///     at `auctionStartTime`, the first scale holds before the start and the last one after the end, so a
    ///     Fusion auction ends with scale 0. Empty `auctionScales` disables, the order is a plain limit order
    ///   - Oracle adjustment, `OraclePriceAdjusterSell`: shifts the maker's receive by the market move since
    ///     the order was priced, `oracleMarketValue` is `balanceOut` valued in token in by the Chainlink-style
    ///     `oracleFeeds` (one or two) at that time, `tokenInDecimals` / `tokenOutDecimals` align the decimals, a
    ///     rise adds to the receive and to the surcharge, a fall consumes the surcharge left so the limit price
    ///     holds. Empty `oracleFeeds` disables, `oracleMarketValue` stays zero
    ///   - Gas bump, `BaseFeeAdjusterSell`: discounts the maker's receive by `gasAmount` units of base fee
    ///     above `baseGasPrice` priced at `ethPrice` token in per 1e18 wei, capped by the surcharge left at that
    ///     moment so the limit price holds. `gasAmount == 0` disables, requires the auction
    ///   - Fills: `allowPartialFills` picks `LimitSwap` over `LimitSwapFullAmount` (fill-or-kill),
    ///     `allowMultipleFills` caps the cumulative output with `InvalidateTokenSell`, otherwise `InvalidateBit`
    ///     with the maker-scoped `nonce` lets the order fill once
    ///   Time fields with `Time.RELATIVE_TIME_FLAG` set count from the order announcement
    function buildFusionOrder(
        bytes[] calldata prefix,
        FusionOrder calldata args
    ) internal pure returns (bytes memory) {
        bool hasWhitelist = args.whitelistResolvers.length > 0;
        bool hasFees = args.feeReceivers.length > 0;
        bool hasGate = args.accessToken != address(0);
        bool hasAuction = args.auctionScales.length > 0;
        bool hasOracle = args.oracleFeeds.length > 0;
        bool hasGasBump = args.gasAmount != 0;
        bool hasSurplus;
        for (uint256 i; i < args.feeReceivers.length; i++) hasSurplus = hasSurplus || args.feeReceivers[i].surplusBps > 0;

        // The whitelist discount needs the whitelist and is at most the whole flat fee
        require(hasWhitelist || args.whitelistFeeDiscount == 0, OrderInconsistent());
        require(args.whitelistFeeDiscount <= FeeProtocol.BPS, OrderInconsistent());
        // Coequal whitelist has no schedule
        require(!args.whitelistCoequal || (args.whitelistStartTime == 0 && args.whitelistDelays.length == 0), OrderInconsistent());
        // Oracle market value goes with the feeds
        require(hasOracle || args.oracleMarketValue == 0, OrderInconsistent());
        // Gas bump consumes the auction surcharge
        require(hasAuction || !hasGasBump, OrderInconsistent());
        // The maker never pays surplus fee on the guaranteed minimum receive
        require(!hasSurplus || args.surplusEstimation >= (args.direction ? args.balanceA : args.balanceB), OrderInconsistent());

        // Whitelisted resolvers pay the same receivers with the discount off the flat fee
        FeeProtocol.ProviderConfig[] memory noProviders;
        FeeProtocol.ReceiverConfig[] memory whitelistedReceivers = new FeeProtocol.ReceiverConfig[](args.feeReceivers.length);
        for (uint256 i; i < whitelistedReceivers.length; i++) {
            whitelistedReceivers[i] = args.feeReceivers[i];
            whitelistedReceivers[i].feeBps = uint24(args.feeReceivers[i].feeBps * (FeeProtocol.BPS - args.whitelistFeeDiscount) / FeeProtocol.BPS);
        }

        MemoryPtr ptrStart = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            (hasWhitelist && args.whitelistCoequal ? WhitelistCoequal.sizeOf(0, args.whitelistResolvers) : 0) +
            (hasWhitelist && !args.whitelistCoequal ? WhitelistSequential.sizeOf(args.whitelistStartTime, 0, args.whitelistResolvers, args.whitelistDelays) : 0) +
            (hasGate ? OnlyTakerTokenBalanceNonZero.sizeOf(args.accessToken) : 0) +
            (hasFees ? FeeProtocol.sizeOf(true, args.feeReceivers, noProviders) : 0) +
            (hasWhitelist ? Jump.sizeOf(0) : 0) +
            (hasWhitelist && hasFees ? FeeProtocol.sizeOf(true, whitelistedReceivers, noProviders) : 0) +
            (hasSurplus ? FeeProtocolSurplus.sizeOf(true, args.surplusEstimation) : 0) +
            (hasAuction ? PiecewiseLinearSurchargeSell.sizeOf(args.auctionStartTime, args.auctionDurations, args.auctionScales) : 0) +
            (hasOracle ? OraclePriceAdjusterSell.sizeOf(args.oracleMarketValue, args.tokenInDecimals, args.tokenOutDecimals, args.oracleFeeds) : 0) +
            (hasGasBump ? BaseFeeAdjusterSell.sizeOf(args.baseGasPrice, args.ethPrice, args.gasAmount) : 0) +
            (args.allowMultipleFills ? InvalidateTokenSell.sizeOf() : InvalidateBit.sizeOf(args.nonce)) +
            (args.allowPartialFills ? LimitSwap.sizeOf(args.direction) : LimitSwapFullAmount.sizeOf(args.direction))
        );

        MemoryPtr ptr = ptrStart;
        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);

        // The whitelist target is patched once the public-only sections it skips are written
        MemoryPtr ptrWhitelist = ptr;
        if (hasWhitelist && args.whitelistCoequal) ptr = WhitelistCoequal.build(ptr, 0, args.whitelistResolvers);
        if (hasWhitelist && !args.whitelistCoequal) ptr = WhitelistSequential.build(ptr, args.whitelistStartTime, 0, args.whitelistResolvers, args.whitelistDelays);

        // Public branch, ends with the jump over the whitelisted one
        if (hasGate) ptr = OnlyTakerTokenBalanceNonZero.build(ptr, args.accessToken);
        if (hasFees) ptr = FeeProtocol.build(ptr, true, args.feeReceivers, noProviders);
        MemoryPtr ptrJump = ptr;
        if (hasWhitelist) ptr = Jump.build(ptr, 0);

        // Whitelisted branch, the jump target is patched once the whitelisted fees it skips are written
        if (hasWhitelist && args.whitelistCoequal) WhitelistCoequal.patchNextPC(ptrWhitelist, ptr.sub(ptrStart).toUint16());
        if (hasWhitelist && !args.whitelistCoequal) WhitelistSequential.patchNextPC(ptrWhitelist, ptr.sub(ptrStart).toUint16());
        if (hasWhitelist && hasFees) ptr = FeeProtocol.build(ptr, true, whitelistedReceivers, noProviders);
        if (hasWhitelist) Jump.patchNextPC(ptrJump, ptr.sub(ptrStart).toUint16());

        if (hasSurplus) ptr = FeeProtocolSurplus.build(ptr, true, args.surplusEstimation);
        if (hasAuction) ptr = PiecewiseLinearSurchargeSell.build(ptr, args.auctionStartTime, args.auctionDurations, args.auctionScales);
        if (hasOracle) ptr = OraclePriceAdjusterSell.build(ptr, args.oracleMarketValue, args.tokenInDecimals, args.tokenOutDecimals, args.oracleFeeds);
        if (hasGasBump) ptr = BaseFeeAdjusterSell.build(ptr, args.baseGasPrice, args.ethPrice, args.gasAmount);
        if (args.allowMultipleFills) ptr = InvalidateTokenSell.build(ptr);
        else ptr = InvalidateBit.build(ptr, args.nonce);
        if (args.allowPartialFills) ptr = LimitSwap.build(ptr, args.direction);
        else ptr = LimitSwapFullAmount.build(ptr, args.direction);

        return ptr.resolve();
    }
}
