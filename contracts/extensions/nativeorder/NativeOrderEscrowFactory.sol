// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { IMakerHooks } from "../../interfaces/IMakerHooks.sol";
import { NativeOrder, NativeOrderEscrow } from "./NativeOrderEscrow.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @title NativeOrderEscrowFactory
/// @notice Deploys a deterministic WETH escrow for each maker-funded native ETH order.
/// @dev Depositing ETH authenticates the maker; takers use the returned NativeOrder as the ERC-1271
/// signature and submit the same SwapVM order with maker replaced by the escrow address.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrowFactory is RouterOrderHasher {
    using Clones for address;

    error NativeOrderZeroDeposit();
    error NativeOrderOnlyMakerCanCreate();
    error NativeOrderAquaNotSupported();
    error NativeOrderExplicitReceiverRequired();
    error NativeOrderExplicitHookTargetRequired();
    error NativeOrderInvalidTokens();
    error NativeOrderInvalidTime();
    error NativeOrderWrongChain();

    /// @notice Emitted when a native order escrow is created and funded.
    /// @param escrow Clone that acts as the maker of the filled order.
    /// @param filledOrderHash Hash of the filled order that takers fill and quote against.
    /// @param nativeOrder Terms committed in the escrow's address. abi.encode(nativeOrder) is the ERC-1271
    /// signature takers supply, and the maker passes it to cancel and rescueFunds.
    /// @param amount Native ETH deposited, held as WETH and approved to the router.
    /// @param filledOrder Order to submit to the router: the maker's order with maker set to the escrow.
    event NativeOrderCreated(
        address indexed escrow,
        bytes32 indexed filledOrderHash,
        NativeOrder nativeOrder,
        uint256 amount,
        ISwapVM.Order filledOrder
    );

    /// @notice Wrapped native token deposits are held in.
    IWETH public immutable WETH;
    /// @notice NativeOrderEscrow implementation all clones delegate to; it also exposes both delays.
    address public immutable ESCROW_IMPLEMENTATION;

    /// @param router SwapVM router that fills the orders; deployment fails if its order hashing differs.
    /// @param weth Wrapped native token deposits are held in.
    /// @param accessToken Token whose holders may publicly cancel expired orders.
    /// @param publicCancellationDelay Seconds after expiration before access-token holders may publicly cancel.
    /// @param rescueDelay Seconds after expiration before the maker may rescue stray funds.
    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 publicCancellationDelay, uint32 rescueDelay)
        RouterOrderHasher(router)
    {
        WETH = weth;
        ESCROW_IMPLEMENTATION = address(
            new NativeOrderEscrow(router, weth, accessToken, publicCancellationDelay, rescueDelay)
        );
    }

    /// @notice Creates and funds an escrow that sells the attached native ETH through the router.
    /// @dev Depositing replaces the maker's signature, so only the maker may create. Only works on the
    /// deployment chain, the one chain where escrows accept fills. Rejects Aqua orders, token pairs that are
    /// unsorted or lack WETH, a receiver that is the escrow or the factory, and hook targets that would
    /// resolve to the escrow.
    /// @param makerOrder Original order, with maker = msg.sender and an explicit receiver and hook targets.
    /// @param expiration Absolute timestamp bounding fills, independently of the program's Deadline. Public
    /// cancellation and rescue open at the implementation's fixed delays after it.
    /// @return escrow The deployed and funded clone.
    /// @return filledOrderHash Hash of the filled order that takers fill and quote against.
    /// @return nativeOrder Terms committed in the escrow's address, needed for fills and cancellations.
    function create(ISwapVM.Order calldata makerOrder, uint40 expiration)
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
            expiration: expiration
        });
        escrow = ESCROW_IMPLEMENTATION.cloneDeterministic(keccak256(abi.encode(nativeOrder)));
        address receiver = makerOrder.traits.receiver(escrow);
        require(receiver != escrow && receiver != address(this), NativeOrderExplicitReceiverRequired());
        _validateHooks(makerOrder, escrow);
        NativeOrderEscrow(payable(escrow)).depositAndApprove{ value: msg.value }();

        filledOrderHash = _hashOrder(escrow, makerOrder.traits, nativeOrder.dataHash);
        emit NativeOrderCreated(
            escrow, filledOrderHash, nativeOrder, msg.value,
            ISwapVM.Order({ maker: escrow, traits: makerOrder.traits, data: makerOrder.data })
        );
    }

    /// @notice Computes the deterministic escrow address for the given terms.
    /// @param order Terms the escrow is or would be created with.
    /// @return Address of the escrow clone for these terms.
    function addressOfEscrow(NativeOrder calldata order) external view returns (address) {
        return ESCROW_IMPLEMENTATION.predictDeterministicAddress(keccak256(abi.encode(order)));
    }

    /// @dev An implicit hook would target the escrow after replacing maker, which cannot execute hooks.
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
