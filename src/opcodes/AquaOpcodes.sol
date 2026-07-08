// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode, OpcodeOps } from "../libs/OpcodeList.sol";

import { Jump, JumpIfTokenIn, JumpIfTokenOut, Deadline, OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte, OnlyTxOriginTokenBalanceNonZero, Salt } from "../instructions/Controls.sol";
import { XYCSwap } from "../instructions/XYCSwap.sol";
import { XYCConcentrate } from "../instructions/XYCConcentrate.sol";
import { Decay } from "../instructions/Decay.sol";
import { Fee } from "../instructions/Fee.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { PeggedSwap } from "../instructions/PeggedSwap.sol";

contract AquaOpcodes is
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee,
    PeggedSwap,
    Extruction
{
    using OpcodeOps for Opcode;

    error UnknownOpcode(uint256 opcode);

    constructor(address aqua) Fee(aqua) {}

    /// @notice Opcode direct dispatcher
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual {
             if (opcode == Jump.opcode.asU8()) Jump.exec(ctx, args);
        else if (opcode == JumpIfTokenIn.opcode.asU8()) JumpIfTokenIn.exec(ctx, args);
        else if (opcode == JumpIfTokenOut.opcode.asU8()) JumpIfTokenOut.exec(ctx, args);
        else if (opcode == Deadline.opcode.asU8()) Deadline.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceNonZero.opcode.asU8()) OnlyTakerTokenBalanceNonZero.exec(ctx, args);
        else if (opcode == OnlyTakerTokenBalanceGte.opcode.asU8()) OnlyTakerTokenBalanceGte.exec(ctx, args);
        else if (opcode == OnlyTakerTokenSupplyShareGte.opcode.asU8()) OnlyTakerTokenSupplyShareGte.exec(ctx, args);
        else if (opcode == uint256(Opcode.XYCSwap)) XYCSwap._xycSwapXD(ctx, args);
        else if (opcode == uint256(Opcode.XYCConcentrateSwap)) XYCConcentrate._xycConcentrateGrowLiquidity2D(ctx, args);
        else if (opcode == uint256(Opcode.Decay)) Decay._decayXD(ctx, args);
        else if (opcode == Salt.opcode.asU8()) Salt.exec(ctx, args);
        else if (opcode == uint256(Opcode.FlatFeeAmountIn)) Fee._flatFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountIn)) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountIn)) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.DynamicProtocolFeeAmountIn)) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaDynamicProtocolFeeAmountIn)) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.PeggedSwap)) PeggedSwap._peggedSwapGrowPriceRange2D(ctx, args);
        else if (opcode == uint256(Opcode.Extruction)) Extruction._extruction(ctx, args);
        else if (opcode == OnlyTxOriginTokenBalanceNonZero.opcode.asU8()) OnlyTxOriginTokenBalanceNonZero.exec(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
