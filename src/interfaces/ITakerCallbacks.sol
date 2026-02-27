// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @title ITakerCallbacks
/// @notice Interface for taker-side callbacks executed during swap lifecycle
interface ITakerCallbacks {
    /// @notice Called before tokenIn is transferred from taker to maker
    /// @param maker Address of the liquidity provider
    /// @param taker Address executing the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    /// @param orderHash Unique identifier for this order/strategy
    /// @param takerData Callback data provided by taker
    function preTransferInCallback(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata takerData
    ) external;

    /// @notice Called before tokenOut is transferred from maker to taker
    /// @param maker Address of the liquidity provider
    /// @param taker Address executing the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    /// @param orderHash Unique identifier for this order/strategy
    /// @param takerData Callback data provided by taker
    function preTransferOutCallback(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata takerData
    ) external;
}
