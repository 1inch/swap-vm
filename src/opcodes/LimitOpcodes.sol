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
import { SeriesEpochManager } from "../instructions/SeriesEpochManager.sol";
import { Whitelist } from "../instructions/Whitelist.sol";
import { PiecewiseLinearScale } from "../instructions/PiecewiseLinearScale.sol";

contract LimitOpcodes is
    Controls,
    Balances,
    Invalidators,
    LimitSwap,
    BaseFeeAdjuster,
    Fee,
    FeeExperimental,
    Extruction,
    SeriesEpochManager,
    Whitelist,
    PiecewiseLinearScale
{
    error UnknownOpcode(uint256 opcode);

    constructor(address aqua) FeeExperimental(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    /// @notice Opcode direct dispatcher
    /// @dev Indices MUST mirror {_opcodes} exactly
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
        else if (opcode == 27) BaseFeeAdjuster._baseFeeAdjuster1D(ctx, args);
        else if (opcode == 29) Extruction._extruction(ctx, args);
        else if (opcode == 30) Controls._salt(ctx, args);
        else if (opcode == 35) FeeExperimental._protocolFeeAmountOutXD(ctx, args);
        else if (opcode == 36) FeeExperimental._aquaProtocolFeeAmountOutXD(ctx, args);
        else if (opcode == 37) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == 38) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 39) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 40) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 41) SeriesEpochManager._validateSeriesEpochXD(ctx, args);
        else if (opcode == 42) Whitelist._privateOrder(ctx, args);
        else if (opcode == 43) Whitelist._whitelistCoequal(ctx, args);
        else if (opcode == 44) PiecewiseLinearScale._piecewiseLinearScaleBalanceIn1D(ctx, args);
        else if (opcode == 45) PiecewiseLinearScale._piecewiseLinearScaleBalanceOut1D(ctx, args);
        else if (opcode == 46) Whitelist._whitelistSequential(ctx, args);
        else revert UnknownOpcode(opcode);
    }

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[48] memory instructions = [
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
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // BaseFeeAdjuster - gas-based price adjustment (dynamic pricing)
            BaseFeeAdjuster._baseFeeAdjuster1D,
            _notInstruction,
            // NOTE: Add new instructions here to maintain backward compatibility
            Extruction._extruction,
            Controls._salt,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            FeeExperimental._protocolFeeAmountOutXD,
            FeeExperimental._aquaProtocolFeeAmountOutXD,
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            SeriesEpochManager._validateSeriesEpochXD,
            Whitelist._privateOrder,
            Whitelist._whitelistCoequal,
            PiecewiseLinearScale._piecewiseLinearScaleBalanceIn1D,
            PiecewiseLinearScale._piecewiseLinearScaleBalanceOut1D,
            Whitelist._whitelistSequential
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
