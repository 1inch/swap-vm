// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IProtocolFeeProvider} from "../src/instructions/interfaces/IProtocolFeeProvider.sol";

/**
 * @title ProtocolFeeProviderMock
 * @notice Mock implementation of IProtocolFeeProvider for testing dynamic protocol fees
 * @dev This contract is used with `_dynamicProtocolFeeAmountInXD`
 *      instructions in SwapVM programs to provide configurable protocol fee parameters.
 *
 * ## Usage in SwapVM Programs
 *
 * Protocol fee instructions must be placed BEFORE balances for correct operation:
 * ```solidity
 * bytes memory bytecode = bytes.concat(
 *     // Dynamic protocol fee BEFORE balances
 *     program.build(_dynamicProtocolFeeAmountInXD, abi.encodePacked(address(feeProvider))),
 *     // Balances instruction
 *     program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(...)),
 *     // Other fees AFTER balances (flat, progressive)
 *     program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)),
 *     // Swap instruction
 *     program.build(_xycSwapXD)
 * );
 * ```
 *
 * ## Fee Calculation
 *
 * The fee is calculated as: `feeAmount = amount * feeBps / 1e9`
 * where feeBps is in basis points with 9 decimal precision (0.001e9 = 0.1%)
 *
 * ## Example
 *
 * ```solidity
 * // Create fee provider with 0.2% fee
 * ProtocolFeeProviderMock feeProvider = new ProtocolFeeProviderMock(
 *     0.002e9,           // feeBps: 0.2% in 1e9 scale
 *     feeRecipient,      // address to receive fees
 *     owner              // owner who can update settings
 * );
 * ```
 *
 * @custom:security This is a mock contract for testing only.
 *                  Production implementations should include access control and validation.
 */
contract ProtocolFeeProviderMock is IProtocolFeeProvider, Ownable {
    struct ProtocolFeeParams {
        /// @notice Fee rate in basis points (1e9 scale, e.g., 0.002e9 = 0.2%)
        uint32 feeBps;
        /// @notice Address that receives protocol fees
        address to;
    }

    ProtocolFeeParams private _params;

    /**
     * @notice Creates a new ProtocolFeeProviderMock
     * @param feeBps Fee rate in basis points (1e9 scale)
     *               Examples: 0.001e9 = 0.1%, 0.002e9 = 0.2%, 0.01e9 = 1%
     * @param to Address to receive collected protocol fees
     * @param owner Address with permission to update fee settings
     */
    constructor(uint32 feeBps, address to, address owner) Ownable(owner) {
        _params.feeBps = feeBps;
        _params.to = to;
    }

    /**
     * @notice Updates fee rate and recipient address
     * @dev Can be called by anyone (no access control in mock)
     *      Production implementation should restrict to owner
     * @param feeBps New fee rate in basis points (1e9 scale)
     * @param to New address to receive protocol fees
     */
    function setFeeBpsAndRecipient(uint32 feeBps, address to) onlyOwner external {
        assembly ("memory-safe") {
            let value := feeBps
            value := or(value, shl(32, to)) // set to
            sstore(_params.slot, value)
        }
    }

    /// @inheritdoc IProtocolFeeProvider
    function getFeeBpsAndRecipient(
        bytes32 /* orderHash */,
        address /* maker */,
        address /* taker */,
        address /* tokenIn */,
        address /* tokenOut */,
        bool /* isExactIn */
    ) external view override returns (uint32 feeBps, address to) {
        assembly ("memory-safe") {
            let params := sload(_params.slot)
            feeBps := and(params, 0xffffffff) // feeBps is in the lower 4 bytes
            to := and(shr(32, params), 0xffffffffffffffffffffffffffffffffffffffff) // to is the next 20 bytes
        }
    }
}
