// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";

/// @title Simple taker contract for direct mode that doesn't interact with Aqua
contract DirectModeTaker {
    SwapVM public immutable SWAPVM;
    address public immutable owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlySwapVM() {
        require(msg.sender == address(SWAPVM), "Not the SwapVM");
        _;
    }

    constructor(SwapVM swapVM, address owner_) {
        SWAPVM = swapVM;
        owner = owner_;
    }

    function swap(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) public onlyOwner returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = SWAPVM.swap(order, tokenIn, tokenOut, amount, takerTraitsAndData);
    }

    // Callback does nothing in direct mode - just validates it was called
    function preTransferInCallback(
        address, address, address, address, uint256, uint256, bytes32, bytes calldata
    ) external view onlySwapVM {
        // No-op for direct mode - tokens transferred directly, not via Aqua
    }

    function preTransferOutCallback(
        address, address, address, address, uint256, uint256, bytes32, bytes calldata
    ) external view onlySwapVM {
        // No-op
    }
}
