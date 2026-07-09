// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";

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

    /// @notice Opcode direct dispatcher
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
             if (opcode == uint256(Opcode.Jump)) Controls._jump(ctx, args);
        else if (opcode == uint256(Opcode.JumpIfTokenIn)) Controls._jumpIfTokenIn(ctx, args);
        else if (opcode == uint256(Opcode.JumpIfTokenOut)) Controls._jumpIfTokenOut(ctx, args);
        else if (opcode == uint256(Opcode.Deadline)) Controls._deadline(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenBalanceNonZero)) Controls._onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenBalanceGte)) Controls._onlyTakerTokenBalanceGte(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenSupplyShareGte)) Controls._onlyTakerTokenSupplyShareGte(ctx, args);
        else if (opcode == uint256(Opcode.StaticBalances)) Balances._staticBalancesXD(ctx, args);
        else if (opcode == uint256(Opcode.InvalidateBit)) Invalidators._invalidateBit1D(ctx, args);
        else if (opcode == uint256(Opcode.InvalidateTokenIn)) Invalidators._invalidateTokenIn1D(ctx, args);
        else if (opcode == uint256(Opcode.InvalidateTokenOut)) Invalidators._invalidateTokenOut1D(ctx, args);
        else if (opcode == uint256(Opcode.LimitSwap)) LimitSwap._limitSwap1D(ctx, args);
        else if (opcode == uint256(Opcode.LimitSwapFullAmount)) LimitSwap._limitSwapOnlyFull1D(ctx, args);
        else if (opcode == uint256(Opcode.BaseFeeAdjuster)) BaseFeeAdjuster._baseFeeAdjuster1D(ctx, args);
        else if (opcode == uint256(Opcode.Extruction)) Extruction._extruction(ctx, args);
        else if (opcode == uint256(Opcode.Salt)) Controls._salt(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountOut)) FeeExperimental._protocolFeeAmountOutXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountOut)) FeeExperimental._aquaProtocolFeeAmountOutXD(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountIn)) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountIn)) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.DynamicProtocolFeeAmountIn)) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaDynamicProtocolFeeAmountIn)) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.ValidateSeriesEpoch)) SeriesEpochManager._validateSeriesEpochXD(ctx, args);
        else if (opcode == uint256(Opcode.PrivateOrder)) Whitelist._privateOrder(ctx, args);
        else if (opcode == uint256(Opcode.WhitelistCoequal)) Whitelist._whitelistCoequal(ctx, args);
        else if (opcode == uint256(Opcode.WhitelistSequential)) Whitelist._whitelistSequential(ctx, args);
        else if (opcode == uint256(Opcode.PiecewiseLinearScaleBalanceIn)) PiecewiseLinearScale._piecewiseLinearScaleBalanceIn1D(ctx, args);
        else if (opcode == uint256(Opcode.PiecewiseLinearScaleBalanceOut)) PiecewiseLinearScale._piecewiseLinearScaleBalanceOut1D(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTxOriginTokenBalanceNonZero)) Controls._onlyTxOriginTokenBalanceNonZero(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
