// SPDX-License-Identifier: MIT
// Vendored from 1inch/cross-chain-swap @ 8b806e28ac00d3749886cb05fad7b2826c7fe743
// (contracts/interfaces/IBaseEscrow.sol). Import paths adjusted for swap-vm; logic unchanged.

pragma solidity ^0.8.0;

import { Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";

import { Timelocks } from "../libraries/TimelocksLib.sol";

/**
 * @title Base Escrow interface for cross-chain atomic swap.
 * @notice Interface implies locking funds initially and then unlocking them with verification of the secret presented.
 * @custom:security-contact security@1inch.io
 */
interface IBaseEscrow {
    struct Immutables {
        bytes32 orderHash;
        bytes32 hashlock;  // Hash of the secret.
        Address maker;
        Address taker;
        Address token;
        uint256 amount;
        uint256 safetyDeposit;
        Timelocks timelocks;
        bytes parameters;  // For now only EscrowDst.withdraw() uses it.
    }

    /**
     * @notice Emitted on escrow cancellation.
     */
    event EscrowCancelled();

    /**
     * @notice Emitted when funds are rescued.
     * @param token The address of the token rescued. Zero address for native token.
     * @param amount The amount of tokens rescued.
     */
    event FundsRescued(address token, uint256 amount);

    /**
     * @notice Emitted on successful withdrawal.
     * @param secret The secret that unlocks the escrow.
     */
    event EscrowWithdrawal(bytes32 secret);

    error InvalidCaller();
    error InvalidImmutables();
    error InvalidSecret();
    error InvalidTime();
    error NativeTokenSendingFailure();

    /* solhint-disable func-name-mixedcase */
    /// @notice Returns the delay for rescuing funds from the escrow.
    function RESCUE_DELAY() external view returns (uint256);
    /// @notice Returns the address of the factory that created the escrow.
    function FACTORY() external view returns (address);
    /* solhint-enable func-name-mixedcase */

    /**
     * @notice Withdraws funds to a predetermined recipient.
     * @dev Withdrawal can only be made during the withdrawal period and with secret with hash matches the hashlock.
     * The safety deposit is sent to the caller.
     * @param secret The secret that unlocks the escrow.
     * @param immutables The immutables of the escrow contract.
     */
    function withdraw(bytes32 secret, Immutables calldata immutables) external;

    /**
     * @notice Cancels the escrow and returns tokens to a predetermined recipient.
     * @dev The escrow can only be cancelled during the cancellation period.
     * The safety deposit is sent to the caller.
     * @param immutables The immutables of the escrow contract.
     */
    function cancel(Immutables calldata immutables) external;

    /**
     * @notice Rescues funds from the escrow.
     * @dev Funds can only be rescued by the taker after the rescue delay.
     * @param token The address of the token to rescue. Zero address for native token.
     * @param amount The amount of tokens to rescue.
     * @param immutables The immutables of the escrow contract.
     */
    function rescueFunds(address token, uint256 amount, Immutables calldata immutables) external;
}
