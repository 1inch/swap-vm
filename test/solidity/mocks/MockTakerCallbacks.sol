// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITakerCallbacks} from "../../../contracts/interfaces/ITakerCallbacks.sol";
import {ISwapVM} from "../../../contracts/interfaces/ISwapVM.sol";
import {SwapVMRouter} from "../../../contracts/routers/SwapVMRouter.sol";

/// @notice Taker callbacks for SwapVM. Just save data used in callbacks.
contract MockTakerCallbacks is ITakerCallbacks {
    SwapVMRouter public immutable SWAPVM;

    bytes public lastPreTransferInData;
    bytes public lastPreTransferOutData;
    uint256 public preTransferInCallCount;
    uint256 public preTransferOutCallCount;

    constructor(SwapVMRouter swapVM) {
        SWAPVM = swapVM;
    }

    function approveToken(address token) external {
        IERC20(token).approve(address(SWAPVM), type(uint256).max);
    }

    function swap(
        ISwapVM.Order calldata order, uint256 amount, bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut, ) = SWAPVM.swap(order,amount,takerTraitsAndData);
    }

    function preTransferInCallback(
        address,address,address,address,uint256,uint256,bytes32,bytes calldata takerData
    ) external {
        lastPreTransferInData = takerData;
        preTransferInCallCount++;
    }

    function preTransferOutCallback(
        address,address,address,address,uint256,uint256,bytes32,bytes calldata takerData
    ) external {
        lastPreTransferOutData = takerData;
        preTransferOutCallCount++;
    }
}
