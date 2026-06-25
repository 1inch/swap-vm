// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

// Sorted by utility: core infrastructure first, then trading instructions
// New instructions should be added at the end to maintain backward compatibility
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

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    function _runLoop(Context memory ctx) internal virtual override(Fee, Decay, VMLoop) { super._runLoop(ctx); }

    /// @notice Opcode direct dispatcher
    /// @dev Indices MUST mirror {_opcodes} exactly
    function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal virtual override {
        if (opcode == 10) Controls._jump(ctx, args);
        else if (opcode == 11) Controls._jumpIfTokenIn(ctx, args);
        else if (opcode == 12) Controls._jumpIfTokenOut(ctx, args);
        else if (opcode == 13) Controls._deadline(ctx, args);
        else if (opcode == 14) Controls._onlyTakerTokenBalanceNonZero(ctx, args);
        else if (opcode == 15) Controls._onlyTakerTokenBalanceGte(ctx, args);
        else if (opcode == 16) Controls._onlyTakerTokenSupplyShareGte(ctx, args);
        else if (opcode == 17) XYCSwap._xycSwapXD(ctx, args);
        else if (opcode == 18) XYCConcentrate._xycConcentrateGrowLiquidity2D(ctx, args);
        else if (opcode == 19) Decay._decayXD(ctx, args);
        else if (opcode == 20) Controls._salt(ctx, args);
        else if (opcode == 21) Fee._flatFeeAmountInXD(ctx, args);
        else if (opcode == 27) Fee._protocolFeeAmountInXD(ctx, args);
        else if (opcode == 28) Fee._aquaProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 29) Fee._dynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 30) Fee._aquaDynamicProtocolFeeAmountInXD(ctx, args);
        else if (opcode == 31) PeggedSwap._peggedSwapGrowPriceRange2D(ctx, args);
        else if (opcode == 32) Extruction._extruction(ctx, args);
        else revert UnknownOpcode(opcode);
    }

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[35] memory instructions = [
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
            // XYCSwap - basic swap (most common swap type)
            XYCSwap._xycSwapXD,
            // XYCConcentrate - liquidity concentration (common AMM feature)
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            // Decay - Decay AMM (specific AMM)
            Decay._decayXD,
            // NOTE: Add new instructions here to maintain backward compatibility
            Controls._salt,
            Fee._flatFeeAmountInXD,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            PeggedSwap._peggedSwapGrowPriceRange2D,
            Extruction._extruction,
            Controls._onlyTxOriginTokenBalanceNonZero
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
