// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { IMakerHooks } from "../../interfaces/IMakerHooks.sol";
import { MakerTraits } from "../../libs/MakerTraits.sol";
import { INativeOrderEscrow } from "./interfaces/INativeOrderEscrow.sol";
import { INativeOrderEscrowFactory } from "./interfaces/INativeOrderEscrowFactory.sol";
import { NativeOrder, NativeOrderLib } from "./libs/NativeOrderLib.sol";
import { NativeOrderEscrow } from "./NativeOrderEscrow.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @title NativeOrderEscrowFactory
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrowFactory is RouterOrderHasher, INativeOrderEscrowFactory {
    using Clones for address;

    IWETH public immutable WETH;
    address public immutable ESCROW_IMPLEMENTATION;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 publicCancellationDelay, uint32 rescueDelay)
        RouterOrderHasher(router)
    {
        WETH = weth;
        ESCROW_IMPLEMENTATION = address(
            new NativeOrderEscrow(router, weth, accessToken, publicCancellationDelay, rescueDelay)
        );
    }

    function create(MakerTraits orderMakerTraits, bytes calldata orderData, uint40 expiration, uint96 maxReward)
        external payable
        returns (address escrow, bytes32 filledOrderHash, NativeOrder memory nativeOrder)
    {
        require(msg.value > 0, NativeOrderZeroDeposit());

        bytes32 dataHash = keccak256(orderData);
        nativeOrder = NativeOrderLib.encode(msg.sender, orderMakerTraits, dataHash, expiration, maxReward);
        escrow = ESCROW_IMPLEMENTATION.cloneDeterministic(nativeOrder.saltMemory());

        require(!orderMakerTraits.useAquaInsteadOfSignature(), NativeOrderAquaNotSupported());
        address receiver = orderMakerTraits.receiver(escrow);
        require(receiver != escrow && receiver != address(this), NativeOrderExplicitReceiverRequired());
        _validateHooks(orderMakerTraits, orderData, escrow);

        (address tokenA, address tokenB) = orderMakerTraits.tokens(orderData);
        require(
            orderData.length >= 40 && tokenA < tokenB && (tokenA == address(WETH) || tokenB == address(WETH)),
            NativeOrderInvalidTokens()
        );

        require(expiration > block.timestamp, NativeOrderInvalidTime());

        INativeOrderEscrow(escrow).depositAndApprove{ value: msg.value }();

        filledOrderHash = _hashOrder(escrow, orderMakerTraits, dataHash);
        emit NativeOrderCreated(
            escrow, filledOrderHash, nativeOrder, msg.value,
            ISwapVM.Order({ maker: escrow, traits: orderMakerTraits, data: orderData })
        );
    }

    function addressOfEscrow(NativeOrder calldata order) external view returns (address) {
        return ESCROW_IMPLEMENTATION.predictDeterministicAddress(order.salt());
    }

    /// @dev Default hook targets would resolve to the escrow, which implements no hooks.
    function _validateHooks(MakerTraits orderMakerTraits, bytes calldata orderData, address escrow) private pure {
        if (orderMakerTraits.hasPreTransferInHook()) {
            (IMakerHooks target,) = orderMakerTraits.preTransferInHook(escrow, orderData);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (orderMakerTraits.hasPostTransferInHook()) {
            (IMakerHooks target,) = orderMakerTraits.postTransferInHook(escrow, orderData);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (orderMakerTraits.hasPreTransferOutHook()) {
            (IMakerHooks target,) = orderMakerTraits.preTransferOutHook(escrow, orderData);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (orderMakerTraits.hasPostTransferOutHook()) {
            (IMakerHooks target,) = orderMakerTraits.postTransferOutHook(escrow, orderData);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
    }
}
