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

contract AquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee
{
    constructor(address aqua) Fee(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[31] memory instructions = [
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
            XYCConcentrate._xycConcentrateGrowLiquidityXD,
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            XYCConcentrate._xycConcentrateGrowPriceRangeXD,
            XYCConcentrate._xycConcentrateGrowPriceRange2D,
            // Decay - Decay AMM (specific AMM)
            Decay._decayXD,
            // NOTE: Add new instructions here to maintain backward compatibility
            Controls._salt,
            Fee._flatFeeAmountInXD,
            Fee._flatFeeAmountOutXD,
            Fee._progressiveFeeInXD,
            Fee._progressiveFeeOutXD,
            Fee._protocolFeeAmountOutXD,
            Fee._aquaProtocolFeeAmountOutXD
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
