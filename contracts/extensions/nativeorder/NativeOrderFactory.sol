// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { Rescuable } from "@1inch/solidity-utils/contracts/mixins/Rescuable.sol";

import { MakerTraits } from "../../libs/MakerTraits.sol";

import { EIP712SwapVM } from "../EIP712SwapVM.sol";
import { NativeOrderEscrow } from "./NativeOrderEscrow.sol";
import { NativeOrder, NativeOrderLib } from "./NativeOrderLib.sol";

contract NativeOrderEscrowFactory is EIP712SwapVM, Rescuable {
    using Clones for address;

    event NativeOrderCreated(address maker, bytes32 orderHash, address clone, uint256 value, NativeOrder saltParams);

    error OrderReceiverShouldBeSet(address receiver);
    error NativeOrderUnsupportedFeatures();

    address public immutable IMPLEMENTATION;

    constructor(address swapVM, IWETH weth, IERC20 accessToken, uint24 cancelDelay) EIP712SwapVM(swapVM) Rescuable(msg.sender) {
        IMPLEMENTATION = address(new NativeOrderEscrow(swapVM, weth, accessToken, cancelDelay));
    }

    function create(MakerTraits traits, bytes32 dataHash, uint40 expiration, uint56 maxBaseFee) external payable
        returns (address escrow)
    {
        address receiver = traits.receiver(escrow);
        require(receiver != address(0) && receiver != address(this), OrderReceiverShouldBeSet(receiver));
        require(!traits.useAquaInsteadOfSignature() && !traits.usePermit2(), NativeOrderUnsupportedFeatures());

        NativeOrder memory nativeOrder = NativeOrderLib.encode(msg.sender, traits, dataHash, expiration, maxBaseFee);

        escrow = IMPLEMENTATION.cloneDeterministic(nativeOrder.saltMem());
        NativeOrderEscrow(payable(escrow)).depositAndApprove{ value: msg.value }();

        bytes32 orderHash = _hashOrder(escrow, traits, dataHash);
        emit NativeOrderCreated(msg.sender, orderHash, escrow, msg.value, nativeOrder);
    }

    function addressOfEscrow(NativeOrder calldata order) external view returns (address) {
        return IMPLEMENTATION.predictDeterministicAddress(order.salt());
    }
}
