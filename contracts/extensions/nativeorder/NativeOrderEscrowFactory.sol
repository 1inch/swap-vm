// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { IMakerHooks } from "../../interfaces/IMakerHooks.sol";
import { INativeOrderEscrow } from "./interfaces/INativeOrderEscrow.sol";
import { INativeOrderEscrowFactory } from "./interfaces/INativeOrderEscrowFactory.sol";
import { NativeOrder } from "./libs/NativeOrderLib.sol";
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

    function create(ISwapVM.Order calldata makerOrder, uint40 expiration, uint96 maxReward)
        external payable
        returns (address escrow, bytes32 filledOrderHash, NativeOrder memory nativeOrder)
    {
        require(_isDeploymentChain(), NativeOrderWrongChain());
        require(msg.value > 0, NativeOrderZeroDeposit());
        require(makerOrder.maker == msg.sender, NativeOrderOnlyMakerCanCreate());
        require(!makerOrder.traits.useAquaInsteadOfSignature(), NativeOrderAquaNotSupported());
        require(expiration > block.timestamp, NativeOrderInvalidTime());

        (address tokenA, address tokenB) = makerOrder.traits.tokens(makerOrder.data);
        require(
            makerOrder.data.length >= 40 && tokenA < tokenB && (tokenA == address(WETH) || tokenB == address(WETH)),
            NativeOrderInvalidTokens()
        );

        nativeOrder = NativeOrder({
            maker: msg.sender,
            traits: makerOrder.traits,
            dataHash: keccak256(makerOrder.data),
            expiration: expiration,
            maxReward: maxReward
        });
        escrow = ESCROW_IMPLEMENTATION.cloneDeterministic(nativeOrder.saltMemory());
        address receiver = makerOrder.traits.receiver(escrow);
        require(receiver != escrow && receiver != address(this), NativeOrderExplicitReceiverRequired());
        _validateHooks(makerOrder, escrow);
        INativeOrderEscrow(escrow).depositAndApprove{ value: msg.value }();

        filledOrderHash = _hashOrder(escrow, makerOrder.traits, nativeOrder.dataHash);
        emit NativeOrderCreated(
            escrow, filledOrderHash, nativeOrder, msg.value,
            ISwapVM.Order({ maker: escrow, traits: makerOrder.traits, data: makerOrder.data })
        );
    }

    function addressOfEscrow(NativeOrder calldata order) external view returns (address) {
        return ESCROW_IMPLEMENTATION.predictDeterministicAddress(order.salt());
    }

    /// @dev Default hook targets would resolve to the escrow, which implements no hooks.
    function _validateHooks(ISwapVM.Order calldata order, address escrow) private pure {
        if (order.traits.hasPreTransferInHook()) {
            (IMakerHooks target,) = order.traits.preTransferInHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPostTransferInHook()) {
            (IMakerHooks target,) = order.traits.postTransferInHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPreTransferOutHook()) {
            (IMakerHooks target,) = order.traits.preTransferOutHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPostTransferOutHook()) {
            (IMakerHooks target,) = order.traits.postTransferOutHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
    }
}
