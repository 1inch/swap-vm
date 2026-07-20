// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IProtocolFeeProvider } from "../src/instructions/interfaces/IProtocolFeeProvider.sol";

/**
 * @title ProtocolFeeProviderMock
 * @notice Mock implementation of IProtocolFeeProvider for testing the FeeProtocol opcode provider flow
 * @dev Returns configurable `(receiver, feeBps, surplusBps)` in 1e7 scale (0.001e7 = 0.1%)
 * @custom:security This is a mock contract for testing only.
 *                  Production implementations should include access control and validation.
 */
contract ProtocolFeeProviderMock is IProtocolFeeProvider, Ownable {
    struct ProtocolFeeParams {
        /// @notice Flat fee rate in basis points (1e7 scale, e.g., 0.002e7 = 0.2%)
        uint24 feeBps;
        /// @notice Surplus fee rate in basis points (1e7 scale)
        uint24 surplusBps;
        /// @notice Address that receives protocol fees
        address receiver;
    }

    ProtocolFeeParams private _params;

    constructor(uint24 feeBps, uint24 surplusBps, address receiver, address owner) Ownable(owner) {
        _params = ProtocolFeeParams({ feeBps: feeBps, surplusBps: surplusBps, receiver: receiver });
    }

    /// @notice Updates fee rates and recipient address
    function setRecipientAndFees(address receiver, uint24 feeBps, uint24 surplusBps) external onlyOwner {
        _params = ProtocolFeeParams({ feeBps: feeBps, surplusBps: surplusBps, receiver: receiver });
    }

    /// @inheritdoc IProtocolFeeProvider
    function getRecipientAndFees(
        bytes32 /* orderHash */,
        address /* maker */,
        address /* taker */,
        address /* tokenIn */,
        address /* tokenOut */,
        bool /* isExactIn */
    ) external view override returns (address receiver, uint24 feeBps, uint24 surplusBps) {
        ProtocolFeeParams memory params = _params;
        return (params.receiver, params.feeBps, params.surplusBps);
    }
}
