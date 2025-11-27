// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

// Sorted by utility: core infrastructure first, then trading instructions
// New instructions should be added at the end to maintain backward compatibility
import { Controls } from "../instructions/Controls.sol";
import { Balances } from "../instructions/Balances.sol";
import { Invalidators } from "../instructions/Invalidators.sol";
import { XYCSwap } from "../instructions/XYCSwap.sol";
import { XYCConcentrate } from "../instructions/XYCConcentrate.sol";
import { Decay } from "../instructions/Decay.sol";
import { LimitSwap } from "../instructions/LimitSwap.sol";
import { MinRate } from "../instructions/MinRate.sol";
import { DutchAuction } from "../instructions/DutchAuction.sol";
import { BaseFeeAdjuster } from "../instructions/BaseFeeAdjuster.sol";
import { TWAPSwap } from "../instructions/TWAPSwap.sol";
import { Fee } from "../instructions/Fee.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { PeggedSwap } from "../instructions/PeggedSwap.sol";

contract Opcodes is
    Controls,
    Balances,
    Invalidators,
    XYCSwap,
    XYCConcentrate,
    Decay,
    LimitSwap,
    MinRate,
    DutchAuction,
    BaseFeeAdjuster,
    TWAPSwap,
    Fee,
    Extruction,
    PeggedSwap
{
    constructor(address aqua) Fee(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[44] memory instructions = [
            _notInstruction,
            // Debug - reserved for debugging utilities (core infrastructure)
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // Controls - control flow (core infrastructure)
            Controls._jump,
            Controls._jumpIfTokenIn,
            Controls._jumpIfTokenOut,
            Controls._deadline,
            Controls._onlyTakerTokenBalanceNonZero,
            Controls._onlyTakerTokenBalanceGte,
            Controls._onlyTakerTokenSupplyShareGte,
            // Balances - balance operations (for AMMs or any other strategies)
            Balances._staticBalancesXD,
            Balances._dynamicBalancesXD,
            // Invalidators - order invalidation (order management)
            Invalidators._invalidateBit1D,
            Invalidators._invalidateTokenIn1D,
            Invalidators._invalidateTokenOut1D,
            // XYCSwap - basic swap (most common swap type)
            XYCSwap._xycSwapXD,
            // XYCConcentrate - liquidity concentration (common AMM feature)
            XYCConcentrate._xycConcentrateGrowLiquidityXD,
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            // Decay - Decay AMM (specific AMM)
            Decay._decayXD,
            // LimitSwap - limit orders (specific trading type)
            LimitSwap._limitSwap1D,
            LimitSwap._limitSwapOnlyFull1D,
            // MinRate - minimum exchange rate enforcement (common trading requirement)
            MinRate._requireMinRate1D,
            MinRate._adjustMinRate1D,
            // DutchAuction - auction mechanism with limit order and time decay (specific trading type)
            DutchAuction._dutchAuctionBalanceIn1D,
            DutchAuction._dutchAuctionBalanceOut1D,
            // BaseFeeAdjuster - gas-based price adjustment (dynamic pricing)
            BaseFeeAdjuster._baseFeeAdjuster1D,
            // TWAPSwap - TWAP trading (complex trading strategy)
            TWAPSwap._twap,
            // NOTE: Add new instructions here to maintain backward compatibility
            Extruction._extruction,
            Controls._salt,
            Fee._flatFeeAmountInXD,
            Fee._flatFeeAmountOutXD,
            Fee._progressiveFeeInXD,
            Fee._progressiveFeeOutXD,
            Fee._protocolFeeAmountOutXD,
            Fee._aquaProtocolFeeAmountOutXD,
            PeggedSwap._peggedSwapGrowPriceRange2D
        ];

        // Efficiently turning static memory array into dynamic memory array
        // by rewriting _notInstruction with array length, so it's excluded from the result
        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
    }
}
