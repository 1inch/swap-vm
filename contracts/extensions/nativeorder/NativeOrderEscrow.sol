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
import { MakerTraits } from "../../libs/MakerTraits.sol";
import { InvalidateTokenOutExternal } from "../../instructions/Invalidators.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @notice Terms committed in the escrow's CREATE2 address.
/// @dev Fixed-size fields only: their abi.encodePacked (101 bytes) is the signature, its keccak256 the salt.
struct NativeOrder {
    address maker;
    MakerTraits traits;
    bytes32 dataHash; // keccak256(order.data)
    uint40 expiration; // fills are rejected from this timestamp
    uint96 maxReward; // max native ETH paid to a public canceller
}

/// @title NativeOrderEscrow
/// @notice Holds one native ETH sell order as WETH, without changing the SwapVM router.
/// @dev The exact router allowance is the order state: fills spend it, cancellation zeros it for good.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrow is OnlyWethReceiver, RouterOrderHasher, IERC1271 {
    using Clones for address;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    error InvalidCaller();
    error InvalidOrder();
    error InvalidTime();
    error OrderClosed();
    error NativeTokenSendingFailure();

    event NativeOrderCancelled(bytes32 indexed orderHash, uint256 refund, uint256 reward);
    event FundsRescued(address indexed token, uint256 amount);

    uint256 private constant _ORDER_SIZE = 101; // 20 + 32 + 32 + 5 + 12

    address public immutable FACTORY = msg.sender;
    IWETH public immutable WETH;
    /// @notice Seconds after expiration before publicCancel opens.
    uint256 public immutable PUBLIC_CANCELLATION_DELAY;
    /// @notice Seconds after expiration before rescueFunds opens.
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

    modifier onlyMaker(NativeOrder calldata order) {
        require(msg.sender == order.maker, InvalidCaller());
        _validateOrder(order);
        _;
    }

    /// @notice Wraps the deposit and approves exactly that amount to the router; called once, by the factory.
    function depositAndApprove() external payable {
        require(msg.sender == FACTORY, InvalidCaller());
        WETH.safeDeposit(msg.value);
        WETH.forceApprove(address(ROUTER), msg.value);
    }

    /// @notice ERC-1271 check: `signature` is the packed NativeOrder this clone was created with.
    /// @dev Skips the allowance: fills of a closed order revert on the zero allowance instead.
    function isValidSignature(bytes32 orderHash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != _ORDER_SIZE || !_isDeploymentChain()) return bytes4(0);
        bytes32 salt;
        MakerTraits traits;
        bytes32 dataHash;
        uint256 expiration;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, signature.offset, _ORDER_SIZE)
            salt := keccak256(ptr, _ORDER_SIZE)
            traits := calldataload(add(signature.offset, 20))
            dataHash := calldataload(add(signature.offset, 52))
            expiration := shr(216, calldataload(add(signature.offset, 84)))
        }
        if (
            !_isCommitted(salt) || block.timestamp >= expiration ||
            _hashOrder(address(this), traits, dataHash) != orderHash
        ) return bytes4(0);
        return IERC1271.isValidSignature.selector;
    }

    /// @notice Closes the order for good, sending all WETH and ETH to the maker; repeatable to sweep donations.
    function cancel(NativeOrder calldata order) external onlyMaker(order) {
        _cancel(order, 0);
    }

    /// @notice After PUBLIC_CANCELLATION_DELAY, an access-token holder may close the order for a reward.
    /// @param rewardLimit Caller's cap; the reward is also capped by maxReward and the remaining WETH.
    function publicCancel(NativeOrder calldata order, uint256 rewardLimit) external {
        _validateOrder(order);
        require(block.timestamp >= order.expiration + PUBLIC_CANCELLATION_DELAY, InvalidTime());
        require(_ACCESS_TOKEN.balanceOf(msg.sender) > 0, InvalidCaller());
        uint256 allowance = WETH.allowance(address(this), address(ROUTER));
        require(allowance > 0, OrderClosed());
        uint256 reward = Math.min(
            Math.min(rewardLimit, order.maxReward), Math.min(allowance, WETH.balanceOf(address(this)))
        );
        _cancel(order, reward);
    }

    /// @notice After RESCUE_DELAY, sends stray tokens to the maker (zero token = ETH); rescuing WETH closes the order.
    function rescueFunds(NativeOrder calldata order, address token, uint256 amount) external onlyMaker(order) {
        require(block.timestamp >= order.expiration + RESCUE_DELAY, InvalidTime());
        if (token == address(WETH)) _closeOrder(order);
        if (token == address(0)) _ethTransfer(order.maker, amount);
        else IERC20(token).safeTransfer(order.maker, amount);
        emit FundsRescued(token, amount);
    }

    function _cancel(NativeOrder calldata order, uint256 reward) private {
        bytes32 orderHash = _closeOrder(order);
        WETH.safeWithdraw(WETH.balanceOf(address(this)));
        // Reward first, so a maker callback cannot rescue the ETH reserved for it.
        _ethTransfer(msg.sender, reward);
        uint256 refund = address(this).balance;
        _ethTransfer(order.maker, refund);
        emit NativeOrderCancelled(orderHash, refund, reward);
    }

    function _closeOrder(NativeOrder calldata order) private returns (bytes32 orderHash) {
        WETH.forceApprove(address(ROUTER), 0);
        orderHash = _hashOrder(address(this), order.traits, order.dataHash);
        // Makes quotes through InvalidateTokenOut fail too, not only fills.
        InvalidateTokenOutExternal(address(ROUTER)).invalidateTokenOut(orderHash, address(WETH));
    }

    function _validateOrder(NativeOrder calldata order) private view {
        require(_isCommitted(_salt(order)), InvalidOrder());
    }

    function _isCommitted(bytes32 salt) private view returns (bool) {
        return _IMPLEMENTATION.predictDeterministicAddress(salt, FACTORY) == address(this);
    }

    /// @dev Shifts drop dirty high bits; Solidity's calldata validation rejects them when the fields are read.
    function _salt(NativeOrder calldata order) private pure returns (bytes32 salt) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(96, calldataload(order)))
            mstore(add(ptr, 20), calldataload(add(order, 0x20)))
            mstore(add(ptr, 52), calldataload(add(order, 0x40)))
            mstore(add(ptr, 84), shl(216, calldataload(add(order, 0x60))))
            mstore(add(ptr, 89), shl(160, calldataload(add(order, 0x80))))
            salt := keccak256(ptr, _ORDER_SIZE)
        }
    }

    function _ethTransfer(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{ value: amount }("");
        require(success, NativeTokenSendingFailure());
    }
}
