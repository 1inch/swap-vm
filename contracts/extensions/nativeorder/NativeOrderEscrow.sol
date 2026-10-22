// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { UniERC20 } from "@1inch/solidity-utils/contracts/libraries/UniERC20.sol";
import { OnlyWethReceiver } from "@1inch/solidity-utils/contracts/mixins/OnlyWethReceiver.sol";

import { EIP712SwapVM } from "../EIP712SwapVM.sol";
import { NativeOrder, NativeOrderLib } from "./NativeOrderLib.sol";

/// @dev Holds native funds and acts as the maker of a SwapVM order, so the user does not need to wrap ETH manually
contract NativeOrderEscrow is OnlyWethReceiver, EIP712SwapVM {
    using Clones for address;
    using UniERC20 for IERC20;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    event NativeOrderCancelled(bytes32 orderHash, uint256 balance);
    event NativeOrderCancelledByResolver(bytes32 orderHash, uint256 balance, uint256 resolverReward);

    error NotFactory(address sender, address factory);
    error NotResolver(address resolver, address accessToken);
    error NotMaker(address sender, address maker);
    error BadOrder(address expected, address actual);
    error NotExpired(uint256 currentTime, uint256 expirationTime);
    error NotAtPublicCancel(uint256 currentTime, uint256 unlockTime);
    error CancelForZeroBalance();
    error ETHTransferFailed();

    uint256 private constant _CANCEL_GAS_REFUND = 70_000;

    address private immutable _FACTORY = msg.sender;
    address private immutable _IMPLEMENTATION = address(this);

    address private immutable _SWAP_VM_ROUTER;
    IWETH private immutable _WETH;
    IERC20 private immutable _ACCESS_TOKEN;
    uint256 private immutable _CANCELLATION_DELAY;

    modifier onlyFactory {
        require(msg.sender == _FACTORY, NotFactory(msg.sender, _FACTORY));
        _;
    }

    modifier onlyResolver {
        require(_ACCESS_TOKEN.safeBalanceOf(msg.sender) > 0, NotResolver(msg.sender, address(_ACCESS_TOKEN)));
        _;
    }

    modifier onlyMaker(NativeOrder calldata order) {
        require(msg.sender == order.maker(), NotMaker(msg.sender, order.maker()));
        _;
    }

    modifier validOrder(NativeOrder calldata order) {
        address escrow = _calcEscrowAddress(order);
        require(escrow == address(this), BadOrder(escrow, address(this)));
        _;
    }

    constructor(address swapVM, IWETH weth, IERC20 accessToken, uint24 cancelDelay) OnlyWethReceiver(address(weth)) EIP712SwapVM(swapVM) {
        _SWAP_VM_ROUTER = swapVM;
        _WETH = weth;
        _ACCESS_TOKEN = accessToken;
        _CANCELLATION_DELAY = cancelDelay;
    }

    /// @dev The factory funds the clone and approves the SwapVM router immediately after deployment
    function depositAndApprove() external payable onlyFactory {
        _WETH.safeDeposit(msg.value);
        _WETH.forceApprove(_SWAP_VM_ROUTER, msg.value);
    }

    /// @dev Validates the SwapVM order whose traits and data hash match the escrow commitment
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != NativeOrderLib.SIZE) return bytes4(0);
        NativeOrder calldata order = NativeOrderLib.wrap(signature);

        bytes32 orderHash = _hashOrder(address(this), order.traits(), order.dataHash());
        if (_calcEscrowAddress(order) != address(this) || orderHash != hash) return bytes4(0);

        return IERC1271.isValidSignature.selector;
    }

    /// @dev The maker may cancel the order at any time
    function cancel(NativeOrder calldata order) external validOrder(order) onlyMaker(order) {
        (uint256 balance, ) = _cancel(order, 0);
        emit NativeOrderCancelled(_hashOrder(address(this), order.traits(), order.dataHash()), balance);
    }

    /// @dev Resolvers may cancel an expired order without receiving a reward
    function cancelExpired(NativeOrder calldata order) external validOrder(order) onlyResolver {
        require(block.timestamp >= order.expiration(), NotExpired(block.timestamp, order.expiration()));

        (uint256 balance, ) = _cancel(order, 0);
        emit NativeOrderCancelledByResolver(_hashOrder(address(this), order.traits(), order.dataHash()), balance, 0);
    }

    /// @dev Resolvers may cancel an expired order for a reward after the cancellation delay has elapsed
    function cancelExpiredForReward(NativeOrder calldata order) external validOrder(order) onlyResolver {
        uint256 unlockTime = order.expiration() + _CANCELLATION_DELAY;
        require(block.timestamp >= unlockTime, NotAtPublicCancel(block.timestamp, unlockTime));

        (uint256 balance, uint256 reward) = _cancel(order, Math.min(block.basefee, order.maxBaseFee()) * _CANCEL_GAS_REFUND);
        emit NativeOrderCancelledByResolver(_hashOrder(address(this), order.traits(), order.dataHash()), balance, reward);
    }

    function _cancel(NativeOrder calldata order, uint256 maxReward) private returns (uint256 balance, uint256 reward) {
        balance = _WETH.safeBalanceOf(address(this));
        require(balance > 0, CancelForZeroBalance());

        _WETH.safeWithdraw(balance);

        if (maxReward > 0) {
            reward = Math.min(maxReward, balance);
            unchecked { balance -= reward; }
            (bool success, ) = msg.sender.call{ value: reward }("");
            require(success, ETHTransferFailed());
        }

        {
            (bool success, ) = order.maker().call{ value: balance }("");
            require(success, ETHTransferFailed());
        }
    }

    function _calcEscrowAddress(NativeOrder calldata order) private view returns (address) {
        return _IMPLEMENTATION.predictDeterministicAddress(order.salt(), _FACTORY);
    }

    function rescueFunds(NativeOrder calldata order, IERC20 token, uint256 amount) external validOrder(order) onlyMaker(order) {
        token.uniTransfer(payable(msg.sender), amount);
    }
}
