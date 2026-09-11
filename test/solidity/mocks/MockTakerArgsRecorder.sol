// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IExtruction } from "../../../contracts/instructions/Extruction.sol";
import { SwapQuery, SwapRegisters } from "../../../contracts/libs/VM.sol";

/// @notice Extruction target that records the taker instruction arguments it receives
contract MockTakerArgsRecorder is IExtruction {
    bytes public lastTakerArgs;
    uint256 public callCount;

    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata ,
        SwapRegisters calldata swap,
        bytes calldata ,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    ) {
        lastTakerArgs = takerData;
        callCount++;
        return (nextPC, 0, swap);
    }
}
