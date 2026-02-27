// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { MakerTraits } from "../libs/MakerTraits.sol";

/// @title ISwapVM
/// @notice Core interface for SwapVM - executes programmable token swap strategies
interface ISwapVM {
    /// @notice Order structure containing maker's swap strategy
    /// @param maker Address of the liquidity provider
    /// @param traits Packed configuration flags and receiver address
    /// @param data Encoded hooks data and program bytecode
    struct Order {
        address maker;
        MakerTraits traits;
        bytes data;
    }

    /// @notice Compute the unique hash for an order
    /// @dev Returns EIP-712 hash for signature-based orders or keccak256(abi.encode(order)) for Aqua orders
    /// @param order The maker's order structure
    /// @return Hash that uniquely identifies this order/strategy
    function hash(Order calldata order) external view returns (bytes32);

    /// @notice Preview swap amounts without executing (static call)
    /// @param order The maker's order containing strategy bytecode
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amount Input amount (if isExactIn) or output amount (if !isExactIn)
    /// @param takerTraitsAndData Packed taker configuration and dynamic data
    /// @return amountIn Computed input token amount
    /// @return amountOut Computed output token amount
    /// @return orderHash Unique identifier for this order
    function quote(
        Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external view returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    /// @notice Execute a swap against a maker's order
    /// @param order The maker's order containing strategy bytecode
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amount Input amount (if isExactIn) or output amount (if !isExactIn)
    /// @param takerTraitsAndData Packed taker configuration and dynamic data
    /// @return amountIn Computed input token amount
    /// @return amountOut Computed output token amount
    /// @return orderHash Unique identifier for this order
    function swap(
        Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}
