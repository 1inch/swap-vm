// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode, OpcodeOps } from "../libs/OpcodeList.sol";

import { Stop, Revert, Jump, JumpIfDirection, JumpIfTokenIn, JumpIfTokenOut, Deadline, OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte, OnlyTxOriginTokenBalanceNonZero, Salt } from "../instructions/Controls.sol";
import { DynamicBalancesExternal, StaticBalances, DynamicBalances } from "../instructions/Balances.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut, InvalidateBitExternal, InvalidateTokenInExternal, InvalidateTokenOutExternal } from "../instructions/Invalidators.sol";
import { XYCSwap } from "../instructions/XYCSwap.sol";
import { XYCConcentrateSwap } from "../instructions/XYCConcentrate.sol";
import { Decay } from "../instructions/Decay.sol";
import { LimitSwap, LimitSwapFullAmount } from "../instructions/LimitSwap.sol";
import { RequireMinRate, AdjustMinRate } from "../instructions/MinRate.sol";
import { DutchAuction } from "../instructions/DutchAuction.sol";
import { BaseFeeAdjuster } from "../instructions/BaseFeeAdjuster.sol";
import { TWAPSwap } from "../instructions/TWAPSwap.sol";
import { Fee } from "../instructions/Fee.sol";
import { FeeExperimental } from "../instructions/FeeExperimental.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { PeggedSwap } from "../instructions/PeggedSwap.sol";
import { SeriesEpochManager } from "../instructions/SeriesEpochManager.sol";
import { Whitelist } from "../instructions/Whitelist.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut } from "../instructions/PiecewiseLinearScale.sol";

contract Opcodes is
    DynamicBalancesExternal,
    InvalidateBitExternal,
    InvalidateTokenInExternal,
    InvalidateTokenOutExternal,
    DutchAuction,
    BaseFeeAdjuster,
    TWAPSwap,
    Fee,
    FeeExperimental,
    PeggedSwap,
    SeriesEpochManager,
    Whitelist
{
    using OpcodeOps for Opcode;

    error UnknownOpcode(uint256 opcode);

    constructor(address aqua) FeeExperimental(aqua) {}

    /// @notice Opcode direct dispatcher
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
             if (opcode == Jump.opcode.asU8()) Jump.exec(ctx, args);
        else if (opcode == Stop.opcode.asU8()) Stop.exec(ctx, args);
        else if (opcode == Revert.opcode.asU8()) Revert.exec(ctx, args);
        else if (opcode == JumpIfDirection.opcode.asU8()) JumpIfDirection.exec(ctx, args);
        else if (opcode == JumpIfTokenIn.opcode.asU8()) JumpIfTokenIn.exec(ctx, args);
        else if (opcode == JumpIfTokenOut.opcode.asU8()) JumpIfTokenOut.exec(ctx, args);
        else if (opcode == Deadline.opcode.asU8()) Deadline.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceNonZero.opcode.asU8()) OnlyTakerTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceGte.opcode.asU8()) OnlyTakerTokenBalanceGte.exec(ctx, args);
        else if (opcode == OnlyTakerTokenSupplyShareGte.opcode.asU8()) OnlyTakerTokenSupplyShareGte.exec(ctx, args);
        else if (opcode == StaticBalances.opcode.asU8()) StaticBalances.exec(ctx, args);
        else if (opcode == DynamicBalances.opcode.asU8()) DynamicBalances.exec(ctx, args);
        else if (opcode == InvalidateBit.opcode.asU8()) InvalidateBit.exec(ctx, args);
        else if (opcode == InvalidateTokenIn.opcode.asU8()) InvalidateTokenIn.exec(ctx, args);
        else if (opcode == InvalidateTokenOut.opcode.asU8()) InvalidateTokenOut.exec(ctx, args);
        else if (opcode == XYCSwap.opcode.asU8()) XYCSwap.exec(ctx, args);
        else if (opcode == XYCConcentrateSwap.opcode.asU8()) XYCConcentrateSwap.exec(ctx, args);
        else if (opcode == Decay.opcode.asU8()) Decay.exec(ctx, args);
        else if (opcode == LimitSwap.opcode.asU8()) LimitSwap.exec(ctx, args);
        else if (opcode == LimitSwapFullAmount.opcode.asU8()) LimitSwapFullAmount.exec(ctx, args);
        else if (opcode == RequireMinRate.opcode.asU8()) RequireMinRate.exec(ctx, args);
        else if (opcode == AdjustMinRate.opcode.asU8()) AdjustMinRate.exec(ctx, args);
        else if (opcode == uint256(Opcode.DutchAuctionBalanceIn)) DutchAuction._dutchAuctionBalanceIn1D(ctx, args);
        else if (opcode == uint256(Opcode.DutchAuctionBalanceOut)) DutchAuction._dutchAuctionBalanceOut1D(ctx, args);
        else if (opcode == uint256(Opcode.BaseFeeAdjuster)) BaseFeeAdjuster._baseFeeAdjuster1D(ctx, args);
        else if (opcode == uint256(Opcode.TWAPSwap)) TWAPSwap._twap(ctx, args);
        else if (opcode == Extruction.opcode.asU8()) Extruction.exec(ctx, args);
        else if (opcode == Salt.opcode.asU8()) Salt.exec(ctx, args);
        else if (opcode == uint256(Opcode.FlatFeeAmountIn)) Fee._flatFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.FlatFeeAmountOut)) FeeExperimental._flatFeeAmountOutXD(ctx, args);
        else if (opcode == uint256(Opcode.ProgressiveFeeIn)) FeeExperimental._progressiveFeeInXD(ctx, args);
        else if (opcode == uint256(Opcode.ProgressiveFeeOut)) FeeExperimental._progressiveFeeOutXD(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountOut)) FeeExperimental._protocolFeeAmountOutXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountOut)) FeeExperimental._aquaProtocolFeeAmountOutXD(ctx, args);
        else if (opcode == uint256(Opcode.PeggedSwap)) PeggedSwap._peggedSwapGrowPriceRange2D(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountIn)) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountIn)) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.DynamicProtocolFeeAmountIn)) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaDynamicProtocolFeeAmountIn)) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.ValidateSeriesEpoch)) SeriesEpochManager._validateSeriesEpochXD(ctx, args);
        else if (opcode == uint256(Opcode.PrivateOrder)) Whitelist._privateOrder(ctx, args);
        else if (opcode == uint256(Opcode.WhitelistCoequal)) Whitelist._whitelistCoequal(ctx, args);
        else if (opcode == PiecewiseLinearScaleBalanceIn.opcode.asU8()) PiecewiseLinearScaleBalanceIn.exec(ctx, args);
        else if (opcode == PiecewiseLinearScaleBalanceOut.opcode.asU8()) PiecewiseLinearScaleBalanceOut.exec(ctx, args);
        else if (opcode == OnlyTxOriginTokenBalanceNonZero.opcode.asU8()) OnlyTxOriginTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == uint256(Opcode.WhitelistSequential)) Whitelist._whitelistSequential(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
