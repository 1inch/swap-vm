// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";

import { Stop, Revert, Deadline, Salt } from "../instructions/Controls.sol";
import { Jump, JumpIfDirection, JumpIfTokenIn, JumpIfTokenOut } from "../instructions/Jumps.sol";
import { OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte, OnlyTxOriginTokenBalanceNonZero } from "../instructions/TokenValidators.sol";
import { StaticBalances } from "../instructions/Balances.sol";
import { InvalidateBit, InvalidateTokenBuy, InvalidateTokenSell, InvalidateBitExternal, InvalidateTokenBuyExternal, InvalidateTokenSellExternal } from "../instructions/Invalidators.sol";
import { LimitSwap, LimitSwapFullAmount } from "../instructions/LimitSwap.sol";
import { BaseFeeAdjusterSell, BaseFeeAdjusterBuy } from "../instructions/BaseFeeAdjuster.sol";
import { FillGridAdjusterSell, FillGridAdjusterBuy } from "../instructions/FillGridAdjuster.sol";
import { FeeProtocol, FeeProtocolSurplus } from "../instructions/FeeProtocol.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { ValidateSeriesEpoch, ValidateSeriesEpochExternal } from "../instructions/SeriesEpochManager.sol";
import { PrivateOrder, WhitelistCoequal, WhitelistSequential } from "../instructions/Whitelist.sol";
import { PiecewiseLinearSurchargeSell, PiecewiseLinearSurchargeBuy } from "../instructions/PiecewiseLinearSurcharge.sol";
import { OraclePriceAdjusterSell, OraclePriceAdjusterBuy } from "../instructions/OraclePriceAdjuster.sol";

contract LimitOpcodes is
    InvalidateBitExternal,
    InvalidateTokenBuyExternal,
    InvalidateTokenSellExternal,
    ValidateSeriesEpochExternal
{
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
        else if (opcode == InvalidateTokenBuy.opcode.asU8()) InvalidateTokenBuy.exec(ctx, args);
        else if (opcode == InvalidateTokenSell.opcode.asU8()) InvalidateTokenSell.exec(ctx, args);
        else if (opcode == LimitSwap.opcode.asU8()) LimitSwap.exec(ctx, args);
        else if (opcode == LimitSwapFullAmount.opcode.asU8()) LimitSwapFullAmount.exec(ctx, args);
        else if (opcode == BaseFeeAdjusterSell.opcode.asU8()) BaseFeeAdjusterSell.exec(ctx, args);
        else if (opcode == BaseFeeAdjusterBuy.opcode.asU8()) BaseFeeAdjusterBuy.exec(ctx, args);
        else if (opcode == FillGridAdjusterSell.opcode.asU8()) FillGridAdjusterSell.exec(ctx, args);
        else if (opcode == FillGridAdjusterBuy.opcode.asU8()) FillGridAdjusterBuy.exec(ctx, args);
        else if (opcode == Extruction.opcode.asU8()) Extruction.exec(ctx, args);
        else if (opcode == Salt.opcode.asU8()) Salt.exec(ctx, args);
        else if (opcode == FeeProtocolSurplus.opcode.asU8()) FeeProtocolSurplus.exec(ctx, args);
        else if (opcode == FeeProtocol.opcode.asU8()) FeeProtocol.exec(ctx, args);
        else if (opcode == ValidateSeriesEpoch.opcode.asU8()) ValidateSeriesEpoch.exec(ctx, args);
        else if (opcode == PrivateOrder.opcode.asU8()) PrivateOrder.exec(ctx, args);
        else if (opcode == WhitelistCoequal.opcode.asU8()) WhitelistCoequal.exec(ctx, args);
        else if (opcode == PiecewiseLinearSurchargeSell.opcode.asU8()) PiecewiseLinearSurchargeSell.exec(ctx, args);
        else if (opcode == PiecewiseLinearSurchargeBuy.opcode.asU8()) PiecewiseLinearSurchargeBuy.exec(ctx, args);
        else if (opcode == OnlyTxOriginTokenBalanceNonZero.opcode.asU8()) OnlyTxOriginTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == WhitelistSequential.opcode.asU8()) WhitelistSequential.exec(ctx, args);
        else if (opcode == OraclePriceAdjusterSell.opcode.asU8()) OraclePriceAdjusterSell.exec(ctx, args);
        else if (opcode == OraclePriceAdjusterBuy.opcode.asU8()) OraclePriceAdjusterBuy.exec(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
