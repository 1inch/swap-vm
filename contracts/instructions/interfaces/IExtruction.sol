// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { SwapQuery, SwapRegisters } from "../../libs/VM.sol";

interface IExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}

interface IStaticExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}
