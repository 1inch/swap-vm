// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";

import { Controls } from "../instructions/Controls.sol";
import { XYCSwap } from "../instructions/XYCSwap.sol";
import { XYCConcentrate } from "../instructions/XYCConcentrate.sol";
import { Decay } from "../instructions/Decay.sol";
import { Fee } from "../instructions/Fee.sol";
import { Extruction } from "../instructions/Extruction.sol";
import { PeggedSwap } from "../instructions/PeggedSwap.sol";

import { VMLoop } from "../VMLoop.sol";

contract AquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee,
    PeggedSwap,
    Extruction,
    VMLoop
{
    error UnknownOpcode(uint256 opcode);

    constructor(address aqua) Fee(aqua) {}

    function _runLoop(Context memory ctx) internal virtual override(Fee, Decay, VMLoop) { super._runLoop(ctx); }

    /// @notice Opcode direct dispatcher
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
             if (opcode == uint256(Opcode.Jump)) Controls._jump(ctx, args);
        else if (opcode == uint256(Opcode.JumpIfTokenIn)) Controls._jumpIfTokenIn(ctx, args);
        else if (opcode == uint256(Opcode.JumpIfTokenOut)) Controls._jumpIfTokenOut(ctx, args);
        else if (opcode == uint256(Opcode.Deadline)) Controls._deadline(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenBalanceNonZero)) Controls._onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenBalanceGte)) Controls._onlyTakerTokenBalanceGte(ctx, args);
        else if (opcode == uint256(Opcode.OnlyTakerTokenSupplyShareGte)) Controls._onlyTakerTokenSupplyShareGte(ctx, args);
        else if (opcode == uint256(Opcode.XYCSwap)) XYCSwap._xycSwapXD(ctx, args);
        else if (opcode == uint256(Opcode.XYCConcentrateSwap)) XYCConcentrate._xycConcentrateGrowLiquidity2D(ctx, args);
        else if (opcode == uint256(Opcode.Decay)) Decay._decayXD(ctx, args);
        else if (opcode == uint256(Opcode.Salt)) Controls._salt(ctx, args);
        else if (opcode == uint256(Opcode.FlatFeeAmountIn)) Fee._flatFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.ProtocolFeeAmountIn)) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaProtocolFeeAmountIn)) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.DynamicProtocolFeeAmountIn)) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.AquaDynamicProtocolFeeAmountIn)) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == uint256(Opcode.PeggedSwap)) PeggedSwap._peggedSwapGrowPriceRange2D(ctx, args);
        else if (opcode == uint256(Opcode.Extruction)) Extruction._extruction(ctx, args);
        else revert UnknownOpcode(opcode);
    }
}
