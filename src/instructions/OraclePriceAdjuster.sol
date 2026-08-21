// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";

/// @notice OraclePriceAdjuster opcode, price adjustment towards a Chainlink oracle price with price percent cap
/// @dev Encoding: [uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals, address oracleAddress]
///   maxStaleness = 0 skips the staleness check, oracleDecimals = 0 fetches decimals from the oracle
/// @dev Supports only single direction swaps, adjustment is applied only if favorable for the taker
library OraclePriceAdjuster {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;
    using SafeCast for int256;

    error OraclePriceAdjusterWrongMaxPriceDecay(uint64 maxPriceDecay);
    error OraclePriceAdjusterOraclePriceStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness);

    Opcode constant opcode = Opcode.OraclePriceAdjuster;

    uint256 constant ONE = 1e18;
    uint8 constant DECIMALS = 18;

    function sizeOf(uint64, uint16, uint8, address) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 8 + 2 + 1 + 20;
    }

    function build(
        uint64 maxPriceDecay,
        uint16 maxStaleness,
        uint8 oracleDecimals,
        address oracleAddress
    ) internal pure returns (bytes memory) {
        return build(
            MemoryPtrLib.alloc(sizeOf(maxPriceDecay, maxStaleness, oracleDecimals, oracleAddress)),
            maxPriceDecay, maxStaleness, oracleDecimals, oracleAddress
        ).resolve();
    }

    function build(MemoryPtr ptrStart, uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals, address oracleAddress) internal pure returns (MemoryPtr ptr) {
        require(maxPriceDecay < ONE, OraclePriceAdjusterWrongMaxPriceDecay(maxPriceDecay));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(maxPriceDecay, 8).push(maxStaleness, 2).push(oracleDecimals).push(oracleAddress);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals, address oracleAddress) {
        maxPriceDecay = args.at(0).asU64();
        maxStaleness = args.at(8).asU16();
        oracleDecimals = args.at(10).asU8();
        oracleAddress = args.at(11).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 maxPriceDecay, uint16 maxStaleness, uint8 oracleDecimals, address oracleAddress) = parse(args);

        // Get latest price data from Chainlink
        IPriceOracle oracle = IPriceOracle(oracleAddress);
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
        if (oracleDecimals < DECIMALS) {
            oraclePrice = oraclePrice * 10 ** (DECIMALS - oracleDecimals);
        } else if (oracleDecimals > DECIMALS) {
            oraclePrice = oraclePrice / 10 ** (oracleDecimals - DECIMALS);
        }

        // Calculate current swap price (tokenOut per tokenIn)
        // Price = amountOut / amountIn
        uint256 currentPrice = (ctx.swap.amountOut * ONE) / ctx.swap.amountIn;

        // Only adjust if oracle price is better for taker
        // If oracle price <= current price, no adjustment (already favorable for taker)
        if (oraclePrice <= currentPrice) return;

        // Oracle shows tokenOut is worth more tokenIn, so taker should get better deal
        if (ctx.query.isExactIn) {
            // exactIn: Taker provides fixed tokenIn, should get more tokenOut
            // Increase amountOut proportionally, but cap at maxIncrease
            uint256 priceRatio = (oraclePrice * ONE) / currentPrice;
            uint256 maxIncrease = (2 * ONE - maxPriceDecay); // Mirror of decay for increase
            uint256 adjustment = Math.min(priceRatio, maxIncrease);
            ctx.swap.amountOut = (ctx.swap.amountOut * adjustment) / ONE;
        } else {
            // exactOut: Taker wants fixed tokenOut, should pay less tokenIn
            // Reduce amountIn proportionally, but cap at maxPriceDecay
            uint256 priceRatio = (currentPrice * ONE) / oraclePrice;
            uint256 adjustment = Math.max(priceRatio, maxPriceDecay);
            ctx.swap.amountIn = (ctx.swap.amountIn * adjustment).ceilDiv(ONE);
        }
    }
}
