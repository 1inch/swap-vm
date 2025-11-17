// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IMakerHooks } from "../../src/interfaces/IMakerHooks.sol";

contract MockMakerHooks is IMakerHooks {
    // Events to track hook calls
    event PreTransferInCalled(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes makerData,
        bytes takerData
    );

    event PostTransferInCalled(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes makerData,
        bytes takerData
    );

    event PreTransferOutCalled(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes makerData,
        bytes takerData
    );

    event PostTransferOutCalled(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes makerData,
        bytes takerData
    );

    // Storage to verify data was passed correctly
    struct HookCallData {
        address maker;
        address taker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        bytes32 orderHash;
        bytes makerData;
        bytes takerData;
    }

    HookCallData public lastPreTransferIn;
    HookCallData public lastPostTransferIn;
    HookCallData public lastPreTransferOut;
    HookCallData public lastPostTransferOut;

    uint256 public preTransferInCallCount;
    uint256 public postTransferInCallCount;
    uint256 public preTransferOutCallCount;
    uint256 public postTransferOutCallCount;

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
    ) external override {
        lastPreTransferIn = HookCallData({
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            orderHash: orderHash,
            makerData: makerData,
            takerData: takerData
        });

        preTransferInCallCount++;

        emit PreTransferInCalled(
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            orderHash,
            makerData,
            takerData
        );
    }

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
    ) external override {
        lastPostTransferIn = HookCallData({
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            orderHash: orderHash,
            makerData: makerData,
            takerData: takerData
        });

        postTransferInCallCount++;

        emit PostTransferInCalled(
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            orderHash,
            makerData,
            takerData
        );
    }

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
    ) external override {
        lastPreTransferOut = HookCallData({
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            orderHash: orderHash,
            makerData: makerData,
            takerData: takerData
        });

        preTransferOutCallCount++;

        emit PreTransferOutCalled(
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            orderHash,
            makerData,
            takerData
        );
    }

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
    ) external override {
        lastPostTransferOut = HookCallData({
            maker: maker,
            taker: taker,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            orderHash: orderHash,
            makerData: makerData,
            takerData: takerData
        });

        postTransferOutCallCount++;

        emit PostTransferOutCalled(
            maker,
            taker,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            orderHash,
            makerData,
            takerData
        );
    }

    // Helper function to verify all hooks were called
    function allHooksCalled() external view returns (bool) {
        return preTransferInCallCount > 0
            && postTransferInCallCount > 0
            && preTransferOutCallCount > 0
            && postTransferOutCallCount > 0;
    }

    // Helper function to reset counters
    function resetCounters() external {
        preTransferInCallCount = 0;
        postTransferInCallCount = 0;
        preTransferOutCallCount = 0;
        postTransferOutCallCount = 0;
    }
}
