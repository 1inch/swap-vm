// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { OnlyWethReceiver } from "@1inch/solidity-utils/contracts/mixins/OnlyWethReceiver.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { InvalidateTokenOutExternal } from "../../instructions/Invalidators.sol";
import { INativeOrderEscrow } from "./interfaces/INativeOrderEscrow.sol";
import { NativeOrder, NativeOrderLib } from "./libs/NativeOrderLib.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @title NativeOrderEscrow
/// @dev The exact router allowance is the order state: fills spend it, cancellation zeros it for good.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrow is OnlyWethReceiver, RouterOrderHasher, INativeOrderEscrow {
    using Clones for address;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    address public immutable FACTORY = msg.sender;
    IWETH public immutable WETH;
    uint256 public immutable PUBLIC_CANCELLATION_DELAY;
    uint256 public immutable RESCUE_DELAY;
    address private immutable _IMPLEMENTATION = address(this);
    IERC20 private immutable _ACCESS_TOKEN;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 publicCancellationDelay, uint32 rescueDelay)
        OnlyWethReceiver(address(weth))
        RouterOrderHasher(router)
    {
        WETH = weth;
        _ACCESS_TOKEN = accessToken;
        PUBLIC_CANCELLATION_DELAY = publicCancellationDelay;
        RESCUE_DELAY = rescueDelay;
    }

    modifier onlyFactory() {
        require(msg.sender == FACTORY, InvalidCaller());
        _;
    }

    modifier onlyMaker(NativeOrder calldata order) {
        require(msg.sender == order.maker(), InvalidCaller());
        _;
    }

    modifier isValidOrder(NativeOrder calldata order) {
        require(_isCommitted(NativeOrderLib.salt(order)), InvalidOrder());
        _;
    }



    function depositAndApprove() external payable onlyFactory {
        WETH.safeDeposit(msg.value);
        WETH.forceApprove(address(ROUTER), msg.value);
    }

    /// @dev Skips the allowance: fills of a closed order revert on the zero allowance instead.
    function isValidSignature(bytes32 orderHash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != NativeOrderLib.SIZE || !_isDeploymentChain()) return bytes4(0);
        NativeOrder calldata order = NativeOrderLib.decode(signature);
        if (
            !_isCommitted(order.salt()) || block.timestamp >= order.expiration() ||
            _hashOrder(address(this), order.traits(), order.dataHash()) != orderHash
        ) return bytes4(0);
        return IERC1271.isValidSignature.selector;
    }

    function cancel(NativeOrder calldata order) external isValidOrder(order) onlyMaker(order) {
        _cancel(order, 0);
    }

    function publicCancel(NativeOrder calldata order) external isValidOrder(order) {
        require(block.timestamp >= order.expiration() + PUBLIC_CANCELLATION_DELAY, InvalidTime());
        require(_ACCESS_TOKEN.balanceOf(msg.sender) > 0, InvalidCaller());
        uint256 allowance = WETH.allowance(address(this), address(ROUTER));
        require(allowance > 0, OrderClosed());
        uint256 reward = Math.min(order.maxReward(), Math.min(allowance, WETH.balanceOf(address(this))));
        _cancel(order, reward);
    }

    function rescueFunds(NativeOrder calldata order, address token, uint256 amount) external isValidOrder(order) onlyMaker(order) {
        require(block.timestamp >= order.expiration() + RESCUE_DELAY, InvalidTime());
        if (token == address(WETH)) _closeOrder(order);
        if (token == address(0)) _ethTransfer(order.maker(), amount);
        else IERC20(token).safeTransfer(order.maker(), amount);
        emit FundsRescued(token, amount);
    }

    function _cancel(NativeOrder calldata order, uint256 reward) private {
        bytes32 orderHash = _closeOrder(order);
        WETH.safeWithdraw(WETH.balanceOf(address(this)));
        // Reward first, so a maker callback cannot rescue the ETH reserved for it.
        _ethTransfer(msg.sender, reward);
        uint256 refund = address(this).balance;
        _ethTransfer(order.maker(), refund);
        emit NativeOrderCancelled(orderHash, refund, reward);
    }

    function _closeOrder(NativeOrder calldata order) private returns (bytes32 orderHash) {
        WETH.forceApprove(address(ROUTER), 0);
        orderHash = _hashOrder(address(this), order.traits(), order.dataHash());
        // Makes quotes through InvalidateTokenOut fail too, not only fills.
        InvalidateTokenOutExternal(address(ROUTER)).invalidateTokenOut(orderHash, address(WETH));
    }

    function _isCommitted(bytes32 salt) private view returns (bool) {
        return _IMPLEMENTATION.predictDeterministicAddress(salt, FACTORY) == address(this);
    }

    function _ethTransfer(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{ value: amount }("");
        require(success, NativeTokenSendingFailure());
    }
}
