// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { ISwapVM } from "../interfaces/ISwapVM.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { MakerTraits, MakerTraitsLib } from "../libs/MakerTraits.sol";

import { ECDSA } from "@1inch/solidity-utils/contracts/libraries/ECDSA.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

library OrderRegistratorLib {
    struct Storage {
        mapping(bytes32 orderHash => uint256) announcedAt;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.OrderRegistrator;
        assembly ("memory-safe") { $.slot := slot }
    }
}

abstract contract OrderRegistrator {
    using ECDSA for address;
    using MakerTraitsLib for MakerTraits;

    /// @dev Emitted when an order is registered.
    event OrderRegistered(ISwapVM.Order order, bytes signature);

    /// @dev Signature verification failed for the order
    error BadSignature(address maker, bytes32 orderHash, bytes signature);
    /// @dev Order already known
    error OrderAlreadyRegistered(bytes32 orderHash);

    IAqua private immutable AQUA;

    constructor(address aqua) {
        AQUA = IAqua(aqua);
    }

    function announcedAt(bytes32 orderHash) external view returns (uint256) {
        OrderRegistratorLib.Storage storage $ = OrderRegistratorLib.store();
        return $.announcedAt[orderHash];
    }

    function hash(ISwapVM.Order calldata) public virtual view returns (bytes32);

    function registerOrder(ISwapVM.Order calldata order, bytes calldata signature) external {
        OrderRegistratorLib.Storage storage $ = OrderRegistratorLib.store();

        bytes32 orderHash = hash(order);

        // Strategy is created with aqua or signed by maker
        if (order.traits.useAquaInsteadOfSignature()) {
            (address tokenA, address tokenB) = order.traits.tokens(order.data);
            AQUA.safeBalances(order.maker, address(this), orderHash, tokenA, tokenB);
        } else {
            require(order.maker.recoverOrIsValidSignature(orderHash, signature), BadSignature(order.maker, orderHash, signature));
        }

        require($.announcedAt[orderHash] == 0, OrderAlreadyRegistered(orderHash));
        $.announcedAt[orderHash] = block.timestamp;

        emit OrderRegistered(order, signature);
    }
}
