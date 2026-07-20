// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode, OpcodeOps } from "../libs/OpcodeList.sol";

import { Jump, JumpIfTokenIn, JumpIfTokenOut, Deadline, OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte, OnlyTxOriginTokenBalanceNonZero, Salt } from "../instructions/Controls.sol";
import { StaticBalances } from "../instructions/Balances.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut, InvalidateBitExternal, InvalidateTokenInExternal, InvalidateTokenOutExternal } from "../instructions/Invalidators.sol";
import { LimitSwap, LimitSwapFullAmount } from "../instructions/LimitSwap.sol";
import { BaseFeeAdjuster } from "../instructions/BaseFeeAdjuster.sol";
import { FeeProtocol } from "../instructions/FeeProtocol.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { ValidateSeriesEpoch, ValidateSeriesEpochExternal } from "../instructions/SeriesEpochManager.sol";
import { PrivateOrder, WhitelistCoequal, WhitelistSequential } from "../instructions/Whitelist.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut } from "../instructions/PiecewiseLinearScale.sol";

contract LimitOpcodes is
    InvalidateBitExternal,
    InvalidateTokenInExternal,
    InvalidateTokenOutExternal,
    BaseFeeAdjuster,
    ValidateSeriesEpochExternal
{
    using OpcodeOps for Opcode;

    error UnknownOpcode(uint256 opcode);

    /// @notice Opcode direct dispatcher
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
             if (opcode == Jump.opcode.asU8()) Jump.exec(ctx, args);
        else if (opcode == JumpIfTokenIn.opcode.asU8()) JumpIfTokenIn.exec(ctx, args);
        else if (opcode == JumpIfTokenOut.opcode.asU8()) JumpIfTokenOut.exec(ctx, args);
        else if (opcode == Deadline.opcode.asU8()) Deadline.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceNonZero.opcode.asU8()) OnlyTakerTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceGte.opcode.asU8()) OnlyTakerTokenBalanceGte.exec(ctx, args);
        else if (opcode == OnlyTakerTokenSupplyShareGte.opcode.asU8()) OnlyTakerTokenSupplyShareGte.exec(ctx, args);
        else if (opcode == StaticBalances.opcode.asU8()) StaticBalances.exec(ctx, args);
        else if (opcode == InvalidateBit.opcode.asU8()) InvalidateBit.exec(ctx, args);
        else if (opcode == InvalidateTokenIn.opcode.asU8()) InvalidateTokenIn.exec(ctx, args);
        else if (opcode == InvalidateTokenOut.opcode.asU8()) InvalidateTokenOut.exec(ctx, args);
        else if (opcode == LimitSwap.opcode.asU8()) LimitSwap.exec(ctx, args);
        else if (opcode == LimitSwapFullAmount.opcode.asU8()) LimitSwapFullAmount.exec(ctx, args);
        else if (opcode == uint256(Opcode.BaseFeeAdjuster)) BaseFeeAdjuster._baseFeeAdjuster1D(ctx, args);
        else if (opcode == Extruction.opcode.asU8()) Extruction.exec(ctx, args);
        else if (opcode == Salt.opcode.asU8()) Salt.exec(ctx, args);
        else if (opcode == FeeProtocol.opcode.asU8()) FeeProtocol.exec(ctx, args);
        else if (opcode == ValidateSeriesEpoch.opcode.asU8()) ValidateSeriesEpoch.exec(ctx, args);
        else if (opcode == PrivateOrder.opcode.asU8()) PrivateOrder.exec(ctx, args);
        else if (opcode == WhitelistCoequal.opcode.asU8()) WhitelistCoequal.exec(ctx, args);
        else if (opcode == PiecewiseLinearScaleBalanceIn.opcode.asU8()) PiecewiseLinearScaleBalanceIn.exec(ctx, args);
        else if (opcode == PiecewiseLinearScaleBalanceOut.opcode.asU8()) PiecewiseLinearScaleBalanceOut.exec(ctx, args);
        else if (opcode == OnlyTxOriginTokenBalanceNonZero.opcode.asU8()) OnlyTxOriginTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == WhitelistSequential.opcode.asU8()) WhitelistSequential.exec(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
