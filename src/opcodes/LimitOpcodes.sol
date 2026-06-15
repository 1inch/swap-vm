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
import { LimitSwap } from "../instructions/LimitSwap.sol";
import { MinRate } from "../instructions/MinRate.sol";
import { DutchAuction } from "../instructions/DutchAuction.sol";
import { BaseFeeAdjuster } from "../instructions/BaseFeeAdjuster.sol";
import { TWAPSwap } from "../instructions/TWAPSwap.sol";
import { Fee } from "../instructions/Fee.sol";
import { FeeExperimental } from "../instructions/FeeExperimental.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { Whitelist } from "../instructions/Whitelist.sol";
import { SeriesEpochManager } from "../instructions/SeriesEpochManager.sol";

contract LimitOpcodes is
    Controls,
    Balances,
    Invalidators,
    LimitSwap,
    MinRate,
    DutchAuction,
    BaseFeeAdjuster,
    TWAPSwap,
    Fee,
    FeeExperimental,
    Extruction,
    Whitelist,
    SeriesEpochManager
{
    error UnknownOpcode(uint256 opcode);

    constructor(address aqua) FeeExperimental(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    /// @notice Opcode dispatcher used on the hot path (see {Opcodes._runOpcode} for rationale).
    /// @dev Indices MUST mirror {_opcodes} exactly; the test suite is the agreement check.
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
        if (opcode == 10) Controls._jump(ctx, args);
        else if (opcode == 11) Controls._jumpIfTokenIn(ctx, args);
        else if (opcode == 12) Controls._jumpIfTokenOut(ctx, args);
        else if (opcode == 13) Controls._deadline(ctx, args);
        else if (opcode == 14) Controls._onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == 15) Controls._onlyTakerTokenBalanceGte(ctx, args);
        else if (opcode == 16) Controls._onlyTakerTokenSupplyShareGte(ctx, args);
        else if (opcode == 17) Balances._staticBalancesXD(ctx, args);
        else if (opcode == 18) Invalidators._invalidateBit1D(ctx, args);
        else if (opcode == 19) Invalidators._invalidateTokenIn1D(ctx, args);
        else if (opcode == 20) Invalidators._invalidateTokenOut1D(ctx, args);
        else if (opcode == 21) LimitSwap._limitSwap1D(ctx, args);
        else if (opcode == 22) LimitSwap._limitSwapOnlyFull1D(ctx, args);
        else if (opcode == 23) MinRate._requireMinRate1D(ctx, args);
        else if (opcode == 24) MinRate._adjustMinRate1D(ctx, args);
        else if (opcode == 25) DutchAuction._dutchAuctionBalanceIn1D(ctx, args);
        else if (opcode == 26) DutchAuction._dutchAuctionBalanceOut1D(ctx, args);
        else if (opcode == 27) BaseFeeAdjuster._baseFeeAdjuster1D(ctx, args);
        else if (opcode == 28) TWAPSwap._twap(ctx, args);
        else if (opcode == 29) Extruction._extruction(ctx, args);
        else if (opcode == 30) Controls._salt(ctx, args);
        else if (opcode == 31) Fee._flatFeeAmountInXD(ctx, args);
        else if (opcode == 32) FeeExperimental._flatFeeAmountOutXD(ctx, args);
        else if (opcode == 33) FeeExperimental._progressiveFeeInXD(ctx, args);
        else if (opcode == 34) FeeExperimental._progressiveFeeOutXD(ctx, args);
        else if (opcode == 35) FeeExperimental._protocolFeeAmountOutXD(ctx, args);
        else if (opcode == 36) FeeExperimental._aquaProtocolFeeAmountOutXD(ctx, args);
        else if (opcode == 37) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == 38) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 39) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 40) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 41) Whitelist._whitelistSingleTaker(ctx, args);
        else if (opcode == 42) Whitelist._whitelistMultipleTakers(ctx, args);
        else if (opcode == 43) SeriesEpochManager._validateSeriesEpochXD(ctx, args);
        // solhint-disable-next-line no-empty-blocks
        else if (opcode < 10) { /* reserved slots 0-9 are no-ops, mirroring _notInstruction */ }
        else revert UnknownOpcode(opcode);
    }

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[45] memory instructions = [
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
            // Balances - balance operations
            Balances._staticBalancesXD,
            // Invalidators - order invalidation (order management)
            Invalidators._invalidateBit1D,
            Invalidators._invalidateTokenIn1D,
            Invalidators._invalidateTokenOut1D,
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
            FeeExperimental._flatFeeAmountOutXD,
            FeeExperimental._progressiveFeeInXD,
            FeeExperimental._progressiveFeeOutXD,
            FeeExperimental._protocolFeeAmountOutXD,
            FeeExperimental._aquaProtocolFeeAmountOutXD,
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            Whitelist._whitelistSingleTaker,
            Whitelist._whitelistMultipleTakers,
            SeriesEpochManager._validateSeriesEpochXD
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
