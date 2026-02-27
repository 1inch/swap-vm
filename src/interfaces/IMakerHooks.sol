// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @title IMakerHooks
/// @notice Interface for maker-side hooks executed during swap lifecycle
/// @custom:security-contact security@1inch.io
interface IMakerHooks {
    /// @notice Called before tokenIn is transferred from taker to maker
    /// @param maker Address of the liquidity provider
    /// @param taker Address executing the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    /// @param orderHash Unique identifier for this order/strategy
    /// @param makerData Hook data from maker's order configuration
    /// @param takerData Hook data provided by taker at execution time
    function preTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;

    /// @notice Called after tokenIn is transferred from taker to maker
    /// @param maker Address of the liquidity provider
    /// @param taker Address executing the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    /// @param orderHash Unique identifier for this order/strategy
    /// @param makerData Hook data from maker's order configuration
    /// @param takerData Hook data provided by taker at execution time
    function postTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
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
    /// @param makerData Hook data from maker's order configuration
    /// @param takerData Hook data provided by taker at execution time
    function preTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;

    /// @notice Called after tokenOut is transferred from maker to taker
    /// @param maker Address of the liquidity provider
    /// @param taker Address executing the swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    /// @param orderHash Unique identifier for this order/strategy
    /// @param makerData Hook data from maker's order configuration
    /// @param takerData Hook data provided by taker at execution time
    function postTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;
}
