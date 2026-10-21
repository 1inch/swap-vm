// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../../interfaces/ISwapVM.sol";
import { NativeOrder } from "./INativeOrderEscrow.sol";
import { IRouterOrderHasher } from "./IRouterOrderHasher.sol";

/// @title INativeOrderEscrowFactory
/// @notice Deploys and funds a deterministic WETH escrow per native ETH sell order.
/// @custom:security-contact security@1inch.io
interface INativeOrderEscrowFactory is IRouterOrderHasher {
    error NativeOrderZeroDeposit();
    error NativeOrderOnlyMakerCanCreate();
    error NativeOrderAquaNotSupported();
    error NativeOrderExplicitReceiverRequired();
    error NativeOrderExplicitHookTargetRequired();
    error NativeOrderInvalidTokens();
    error NativeOrderInvalidTime();
    error NativeOrderWrongChain();

    event NativeOrderCreated(
        address indexed escrow,
        bytes32 indexed filledOrderHash,
        NativeOrder nativeOrder,
        uint256 amount,
        ISwapVM.Order filledOrder
    );

    function WETH() external view returns (IWETH);
    function ESCROW_IMPLEMENTATION() external view returns (address);

    /// @notice Escrows msg.value for `makerOrder`. Takers fill it with maker = escrow and the packed
    /// `nativeOrder` as the signature.
    /// @dev Only the maker may create: the deposit replaces their signature.
    /// @param expiration Timestamp from which fills are rejected; the escrow's delays count from it.
    /// @param maxReward Max native ETH paid to a public canceller; zero offers no reward.
    function create(ISwapVM.Order calldata makerOrder, uint40 expiration, uint96 maxReward)
        external payable
        returns (address escrow, bytes32 filledOrderHash, NativeOrder memory nativeOrder);

    /// @notice Escrow address for `order`, deployed or not.
    function addressOfEscrow(NativeOrder calldata order) external view returns (address);
}
