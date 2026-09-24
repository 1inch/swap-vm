// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { AddressLib, Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { OnlyWethReceiver } from "@1inch/solidity-utils/contracts/mixins/OnlyWethReceiver.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { IBaseEscrow } from "./vendor/interfaces/IBaseEscrow.sol";
import { ImmutablesLib } from "./vendor/libraries/ImmutablesLib.sol";
import { Timelocks, TimelocksLib } from "./vendor/libraries/TimelocksLib.sol";
import { ProxyHashLib } from "./vendor/libraries/ProxyHashLib.sol";

/// @title NativeOrderEscrow
/// @notice Per-order escrow clone that lets a maker sell native ETH through an unmodified SwapVM router.
/// @dev Deployed by NativeOrderEscrowFactory via CREATE2 with salt = hash(IBaseEscrow.Immutables), mirroring
/// the cross-chain-swap EscrowSrc/EscrowDst integrity model: the clone is stateless and every call passes the
/// full immutables pack, re-authenticated against the clone's own address (CREATE2 self-proof).
///
/// Roles of the immutables fields (Fusion+ layout, unused fields zeroed for cross-chain morphability):
/// - orderHash:     hash of the PRE-PATCH order (maker = real maker) - resolves CREATE2 circularity
/// - hashlock:      0 (reserved for the cross-chain variant)
/// - maker:         the real maker EOA - receives cancellation refunds, may rescue funds
/// - taker:         0 (reserved)
/// - token:         WETH
/// - amount:        ETH deposited at creation (informational; live WETH balance is authoritative)
/// - safetyDeposit: 0 (reserved)
/// - timelocks:     SrcCancellation = order expiry, SrcPublicCancellation = public GC start, plus deployedAt
///
/// The clone acts as `order.maker` of the patched order: it wraps the deposit to WETH, approves the router,
/// and validates fills via ERC-1271 where the signature bytes carry abi.encode(immutables, prePatchOrder).
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrow is OnlyWethReceiver, IERC1271 {
    using AddressLib for Address;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using TimelocksLib for Timelocks;
    using ImmutablesLib for IBaseEscrow.Immutables;

    error MakerOrderMismatch();
    error FilledOrderMismatch();

    /// @notice Gas budget compensated to the resolver performing a public cancellation.
    uint256 private constant _PUBLIC_CANCEL_GAS_COST = 120_000;
    /// @notice Premium (in percent) over the base fee applied to the public cancellation reward.
    uint256 private constant _PUBLIC_CANCEL_REWARD_PREMIUM = 110;

    /// @notice Factory that deployed this implementation and its clones.
    address public immutable FACTORY = msg.sender;
    /// @notice Hash of the EIP-1167 proxy bytecode pointing at this implementation.
    bytes32 public immutable PROXY_BYTECODE_HASH = ProxyHashLib.computeProxyBytecodeHash(address(this));
    /// @notice SwapVM router the clone approves and validates orders for.
    ISwapVM public immutable ROUTER;
    /// @notice Wrapped native token the escrowed ETH is held in.
    IWETH public immutable WETH;
    /// @notice Delay after deployment when the maker may rescue stray funds.
    uint256 public immutable RESCUE_DELAY;

    /// @dev Token that gates the public cancellation path to registered resolvers.
    IERC20 private immutable _ACCESS_TOKEN;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 rescueDelay)
        OnlyWethReceiver(address(weth))
    {
        ROUTER = router;
        WETH = weth;
        _ACCESS_TOKEN = accessToken;
        RESCUE_DELAY = rescueDelay;
    }

    modifier onlyCaller(address expected) {
        if (msg.sender != expected) revert IBaseEscrow.InvalidCaller();
        _;
    }

    modifier onlyValidImmutables(IBaseEscrow.Immutables calldata immutables) {
        _validateImmutables(immutables.hash());
        _;
    }

    modifier onlyAfter(uint256 start) {
        if (block.timestamp < start) revert IBaseEscrow.InvalidTime();
        _;
    }

    modifier onlyAccessTokenHolder() {
        if (_ACCESS_TOKEN.balanceOf(msg.sender) == 0) revert IBaseEscrow.InvalidCaller();
        _;
    }

    /// @notice Wraps the ETH deposit into WETH and approves the router to pull it during fills.
    /// @dev Called exactly once by the factory right after the clone is deployed.
    function depositAndApprove() external payable onlyCaller(FACTORY) {
        WETH.safeDeposit(msg.value);
        IERC20(address(WETH)).forceApprove(address(ROUTER), type(uint256).max);
    }

    /// @notice ERC-1271 validation called by the router when this clone is `order.maker`.
    /// @dev The signature bytes carry abi.encode(immutables, prePatchOrder). Three links are verified:
    /// 1. immutables authenticate against this clone's CREATE2 address (binds amount, maker, timelocks);
    /// 2. the carried pre-patch order hashes to immutables.orderHash (binds the full order content);
    /// 3. the order patched with maker = address(this) hashes to `orderHash` being validated by the router.
    /// @param orderHash Hash of the patched order the router is executing.
    /// @param signature abi.encode(IBaseEscrow.Immutables, ISwapVM.Order) - the pre-patch order.
    /// @return magicValue ERC-1271 magic value on success.
    function isValidSignature(bytes32 orderHash, bytes calldata signature) external view returns (bytes4) {
        (IBaseEscrow.Immutables memory immutables, ISwapVM.Order memory makerOrder) =
            abi.decode(signature, (IBaseEscrow.Immutables, ISwapVM.Order));

        _validateImmutables(immutables.hashMem());
        if (ROUTER.hash(makerOrder) != immutables.orderHash) revert MakerOrderMismatch();

        makerOrder.maker = address(this);
        if (ROUTER.hash(makerOrder) != orderHash) revert FilledOrderMismatch();

        return IERC1271.isValidSignature.selector;
    }

    /// @notice Cancels the order: unwraps the remaining WETH and refunds native ETH to the maker.
    /// @dev Callable by the maker at any time (before expiry or to sweep a partial-fill remainder).
    /// Subsequent fills fail on transferFrom since the balance is gone.
    /// @param immutables The escrow immutables (validated against the clone address).
    function cancel(IBaseEscrow.Immutables calldata immutables)
        external
        onlyCaller(immutables.maker.get())
        onlyValidImmutables(immutables)
    {
        WETH.safeWithdraw(WETH.balanceOf(address(this)));
        _ethTransfer(immutables.maker.get(), address(this).balance);
        emit IBaseEscrow.EscrowCancelled();
    }

    /// @notice Public cancellation after the SrcPublicCancellation stage: any access-token holder may
    /// garbage-collect an abandoned order for a base-fee-capped reward; the remainder refunds the maker.
    /// @param immutables The escrow immutables (validated against the clone address).
    /// @param rewardLimit Upper bound on the reward the caller accepts (0 = altruistic cancel).
    function publicCancel(IBaseEscrow.Immutables calldata immutables, uint256 rewardLimit)
        external
        onlyAccessTokenHolder
        onlyValidImmutables(immutables)
        onlyAfter(immutables.timelocks.get(TimelocksLib.Stage.SrcPublicCancellation))
    {
        WETH.safeWithdraw(WETH.balanceOf(address(this)));
        uint256 balance = address(this).balance;
        uint256 reward = Math.min(
            Math.min(rewardLimit, balance),
            block.basefee * _PUBLIC_CANCEL_GAS_COST * _PUBLIC_CANCEL_REWARD_PREMIUM / 100
        );
        _ethTransfer(immutables.maker.get(), balance - reward);
        if (reward > 0) _ethTransfer(msg.sender, reward);
        emit IBaseEscrow.EscrowCancelled();
    }

    /// @notice Rescues stray funds (any token or native ETH) to the maker after the rescue delay.
    /// @dev Mirrors BaseEscrow.rescueFunds with maker in place of taker as the privileged party.
    /// @param token Token to rescue (zero address for native ETH).
    /// @param amount Amount to rescue.
    /// @param immutables The escrow immutables (validated against the clone address).
    function rescueFunds(address token, uint256 amount, IBaseEscrow.Immutables calldata immutables)
        external
        onlyCaller(immutables.maker.get())
        onlyValidImmutables(immutables)
        onlyAfter(immutables.timelocks.rescueStart(RESCUE_DELAY))
    {
        _uniTransfer(token, msg.sender, amount);
        emit IBaseEscrow.FundsRescued(token, amount);
    }

    /// @dev Verifies that the computed escrow address matches the address of this contract.
    function _validateImmutables(bytes32 immutablesHash) internal view {
        if (Create2.computeAddress(immutablesHash, PROXY_BYTECODE_HASH, FACTORY) != address(this)) {
            revert IBaseEscrow.InvalidImmutables();
        }
    }

    /// @dev Transfers ERC20 or native tokens to the recipient.
    function _uniTransfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            _ethTransfer(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Transfers native tokens to the recipient.
    function _ethTransfer(address to, uint256 amount) internal {
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert IBaseEscrow.NativeTokenSendingFailure();
    }
}
