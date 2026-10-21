// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { ISwapVM } from "../../../interfaces/ISwapVM.sol";

/// @title IRouterOrderHasher
/// @notice SwapVM router whose signature-order hashes are reproduced locally.
/// @custom:security-contact security@1inch.io
interface IRouterOrderHasher {
    error RouterOrderHashMismatch();

    function ROUTER() external view returns (ISwapVM);
}
