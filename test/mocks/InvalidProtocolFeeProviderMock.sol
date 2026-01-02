// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import "../../src/instructions/interfaces/IProtocolFeeProvider.sol";

contract InvalidProtocolFeeProviderMock is IProtocolFeeProvider {
    error FeeDynamicProtocolInvalidRecipient();

    /// @inheritdoc IProtocolFeeProvider
    function getFeeBpsAndRecipient(
        bytes32 /* orderHash */,
        address /* maker */,
        address /* taker */,
        address /* tokenIn */,
        address /* tokenOut */,
        bool /* isExactIn */
    ) external pure override returns (uint32, address) {
        revert FeeDynamicProtocolInvalidRecipient();
    }
}
