// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";

import { MockTaker } from "./MockTaker.sol";

contract MockTakerFirstTransfer is MockTaker {
    constructor(Aqua aqua, SwapVM swapVM, address owner_) MockTaker(aqua, swapVM, owner_) {}

    function preTransferInCallback(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata takerData
    ) public override onlySwapVM {
        super.preTransferInCallback(
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            orderHash,
            takerData
        );
        ERC20(tokenOut).transfer(maker, amountOut); // transfer tokenOut to maker for checking that
                                                    // preTransferInCallback is called before maker transfer
    }
}
