// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ITakerCallbacks } from "../../src/interfaces/ITakerCallbacks.sol";
import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";

/// @dev Mock taker that can be configured to have broken callback behavior for testing
contract MockTakerBrokenCallback is ITakerCallbacks {
    enum CallbackBehavior {
        Normal,           // Push correct amount to Aqua
        NoPush,           // Don't push anything
        InsufficientPush, // Push less than required
        WrongOrderHash,   // Push to wrong orderHash
        WrongToken        // Push wrong token
    }

    Aqua public immutable AQUA;
    SwapVM public immutable SWAPVM;
    address public immutable owner;

    CallbackBehavior public behavior;
    uint256 public pushAmountOverride; // For InsufficientPush: how much to push

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlySwapVM() {
        require(msg.sender == address(SWAPVM), "Not the SwapVM");
        _;
    }

    constructor(Aqua aqua, SwapVM swapVM, address owner_) {
        AQUA = aqua;
        SWAPVM = swapVM;
        owner = owner_;
        behavior = CallbackBehavior.Normal;
    }

    function setBehavior(CallbackBehavior _behavior) external onlyOwner {
        behavior = _behavior;
    }

    function setPushAmountOverride(uint256 _amount) external onlyOwner {
        pushAmountOverride = _amount;
    }

    function swap(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) public onlyOwner returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = SWAPVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerTraitsAndData
        );
    }

    function preTransferInCallback(
        address maker,
        address /* taker */,
        address tokenIn,
        address /* tokenOut */,
        uint256 amountIn,
        uint256 /* amountOut */,
        bytes32 orderHash,
        bytes calldata /* takerData */
    ) public virtual onlySwapVM {
        if (behavior == CallbackBehavior.NoPush) {
            // Don't push anything - swap should fail
            return;
        }

        if (behavior == CallbackBehavior.InsufficientPush) {
            // Push less than required
            uint256 pushAmount = pushAmountOverride > 0 ? pushAmountOverride : amountIn / 2;
            ERC20(tokenIn).approve(address(AQUA), pushAmount);
            AQUA.push(maker, address(SWAPVM), orderHash, tokenIn, pushAmount);
            return;
        }

        if (behavior == CallbackBehavior.WrongOrderHash) {
            // Push to wrong orderHash
            bytes32 wrongOrderHash = keccak256(abi.encodePacked("wrong", orderHash));
            ERC20(tokenIn).approve(address(AQUA), amountIn);
            AQUA.push(maker, address(SWAPVM), wrongOrderHash, tokenIn, amountIn);
            return;
        }

        // Normal behavior - push correct amount
        ERC20(tokenIn).approve(address(AQUA), amountIn);
        AQUA.push(maker, address(SWAPVM), orderHash, tokenIn, amountIn);
    }

    function preTransferOutCallback(
        address /* maker */,
        address /* taker */,
        address /* tokenIn */,
        address /* tokenOut */,
        uint256 /* amountIn */,
        uint256 /* amountOut */,
        bytes32 /* orderHash */,
        bytes calldata /* takerData */
    ) public virtual onlySwapVM {
        // No-op for this mock
    }
}
