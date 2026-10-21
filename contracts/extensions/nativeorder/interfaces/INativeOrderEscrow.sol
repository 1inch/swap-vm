// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { MakerTraits } from "../../../libs/MakerTraits.sol";
import { IRouterOrderHasher } from "./IRouterOrderHasher.sol";

/// @notice Terms committed in the escrow's CREATE2 address.
/// @dev Fixed-size fields only: their abi.encodePacked (101 bytes) is the signature, its keccak256 the salt.
struct NativeOrder {
    address maker;
    MakerTraits traits;
    bytes32 dataHash; // keccak256(order.data)
    uint40 expiration; // fills are rejected from this timestamp
    uint96 maxReward; // max native ETH paid to a public canceller
}

/// @title INativeOrderEscrow
/// @notice Holds one native ETH sell order as WETH, without changing the SwapVM router.
/// @custom:security-contact security@1inch.io
interface INativeOrderEscrow is IERC1271, IRouterOrderHasher {
    error InvalidCaller();
    error InvalidOrder();
    error InvalidTime();
    error OrderClosed();
    error NativeTokenSendingFailure();

    event NativeOrderCancelled(bytes32 indexed orderHash, uint256 refund, uint256 reward);
    event FundsRescued(address indexed token, uint256 amount);

    function FACTORY() external view returns (address);
    function WETH() external view returns (IWETH);
    /// @notice Seconds after expiration before publicCancel opens.
    function PUBLIC_CANCELLATION_DELAY() external view returns (uint256);
    /// @notice Seconds after expiration before rescueFunds opens.
    function RESCUE_DELAY() external view returns (uint256);

    /// @notice Wraps the deposit and approves exactly that amount to the router; called once at creation.
    function depositAndApprove() external payable;

    /// @notice Closes the order for good, sending all WETH and ETH to the maker; repeatable to sweep donations.
    function cancel(NativeOrder calldata order) external;

    /// @notice After PUBLIC_CANCELLATION_DELAY, an access-token holder may close the order for a reward.
    /// @param rewardLimit Caller's cap; the reward is also capped by maxReward and the remaining WETH.
    function publicCancel(NativeOrder calldata order, uint256 rewardLimit) external;

    /// @notice After RESCUE_DELAY, sends stray tokens to the maker (zero token = ETH); rescuing WETH closes the order.
    function rescueFunds(NativeOrder calldata order, address token, uint256 amount) external;
}
