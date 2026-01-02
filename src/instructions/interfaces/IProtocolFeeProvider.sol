// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @notice Protocol fee provider interface
interface IProtocolFeeProvider {
    /// @notice Returns the protocol fee in bps (1e9 = 100%) for the given order hash
    /// @param orderHash The hash of the order
    /// @param maker The address of the maker
    /// @param taker The address of the taker
    /// @param tokenIn The address of the input token
    /// @param tokenOut The address of the output token
    /// @param isExactIn True if the swap is exact input, false if exact output
    /// @return feeBps The protocol fee in basis points
    /// @return to The address to which the fee should be sent
    function getFeeBpsAndRecipient(
        bytes32 orderHash,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        bool isExactIn
    ) external view returns (uint32, address);
}
