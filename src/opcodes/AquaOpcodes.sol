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
import { XYCConcentrateExperimental } from "../instructions/XYCConcentrateExperimental.sol";
import { Decay } from "../instructions/Decay.sol";
import { Fee } from "../instructions/Fee.sol";
import { FeeExperimental } from "../instructions/FeeExperimental.sol";

contract AquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    XYCConcentrateExperimental,
    Decay,
    Fee,
    FeeExperimental
{
    constructor(address aqua) FeeExperimental(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

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
            XYCConcentrate._xycConcentrateGrowLiquidityXD,
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            XYCConcentrateExperimental._xycConcentrateGrowPriceRangeXD,
            XYCConcentrateExperimental._xycConcentrateGrowPriceRange2D,
            // Decay - Decay AMM (specific AMM)
            Decay._decayXD,
            // NOTE: Add new instructions here to maintain backward compatibility
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
            Fee._aquaDynamicProtocolFeeAmountInXD
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
