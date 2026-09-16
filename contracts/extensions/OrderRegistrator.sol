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
    /// @dev Order already known
    error OrderAlreadyRegistered(bytes32 orderHash);

    struct Storage {
        mapping(bytes32 orderHash => uint40) announcedAt;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.OrderRegistrator;
        assembly ("memory-safe") { $.slot := slot }
    }

    /// @dev Announce new order, revert if already known
    function announce(bytes32 orderHash) internal {
        Storage storage $ = OrderRegistratorLib.store();

        require($.announcedAt[orderHash] == 0, OrderAlreadyRegistered(orderHash));
        $.announcedAt[orderHash] = uint40(block.timestamp);
    }

    /// @dev Order announcement time, lazy-initialized
    function announcedAt(bytes32 orderHash, bool isStaticContext) internal returns (uint40 ts) {
        Storage storage $ = OrderRegistratorLib.store();

        ts = $.announcedAt[orderHash];
        if (ts == 0) {
            ts = uint40(block.timestamp);
            if (!isStaticContext) $.announcedAt[orderHash] = ts;
        }
    }
}

abstract contract OrderRegistrator {
    using ECDSA for address;
    using MakerTraitsLib for MakerTraits;

    /// @dev Emitted when an order is registered.
    event OrderRegistered(ISwapVM.Order order, bytes signature);

    /// @dev Signature verification failed for the order
    error BadSignature(address maker, bytes32 orderHash, bytes signature);

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
        bytes32 orderHash = hash(order);

        // Strategy is created with aqua or signed by maker
        if (order.traits.useAquaInsteadOfSignature()) {
            (address tokenA, address tokenB) = order.traits.tokens(order.data);
            AQUA.safeBalances(order.maker, address(this), orderHash, tokenA, tokenB);
        } else {
            require(order.maker.recoverOrIsValidSignature(orderHash, signature), BadSignature(order.maker, orderHash, signature));
        }

        OrderRegistratorLib.announce(orderHash);
        emit OrderRegistered(order, signature);
    }
}
