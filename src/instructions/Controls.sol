// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library ControlsArgsBuilder {
    function buildSalt(uint64 salt) internal pure returns (bytes memory) {
        return abi.encodePacked(salt);
    }

    function buildSalt(bytes memory salt) internal pure returns (bytes memory) {
        return salt;
    }

    function buildJump(uint16 nextPC) internal pure returns (bytes memory) {
        return abi.encodePacked(nextPC);
    }

    function buildJumpIfToken(address token, uint16 nextPC) internal pure returns (bytes memory) {
        return abi.encodePacked(nextPC, token);
    }

    function buildDeadline(uint40 deadline) internal pure returns (bytes memory) {
        return abi.encodePacked(deadline);
    }

    function buildTakerTokenBalanceNonZero(address token) internal pure returns (bytes memory) {
        return abi.encodePacked(token);
    }

    function buildTakerTokenBalanceGte(address token, uint256 minAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(minAmount, token);
    }

    function buildTakerTokenSupplyShareGte(address token, uint64 minShareE18) internal pure returns (bytes memory) {
        return abi.encodePacked(minShareE18, token);
    }

    function parseJump(bytes calldata args) internal pure returns (uint256 nextPC) {
        assembly ("memory-safe") {
            nextPC := shr(240, calldataload(args.offset))
        }
    }

    function parseJumpIfToken(bytes calldata args) internal pure returns (address token, uint256 nextPC) {
        assembly ("memory-safe") {
            nextPC := shr(240, calldataload(args.offset))
            // leaves 2 dirty bytes out of type declaration, fine for solidity but might harm asm processing
            token := shr(80, calldataload(args.offset))
        }
    }

    function parseDeadline(bytes calldata args) internal pure returns (uint256 deadline) {
        assembly ("memory-safe") {
            deadline := shr(216, calldataload(args.offset))
        }
    }

    function parseTakerTokenBalanceNonZero(bytes calldata args) internal pure returns (address token) {
        assembly ("memory-safe") {
            token := shr(96, calldataload(args.offset))
        }
    }

    function parseTakerTokenBalanceGte(bytes calldata args) internal pure returns (address token, uint256 minAmount) {
        assembly ("memory-safe") {
            minAmount := calldataload(args.offset)
            token := shr(96, calldataload(add(args.offset, 32)))
        }
    }

    function parseTakerTokenSupplyShareGte(bytes calldata args) internal pure returns (address token, uint256 minShareE18) {
        assembly ("memory-safe") {
            minShareE18 := shr(192, calldataload(args.offset))
            // leaves 8 dirty bytes out of type declaration, fine for solidity but might harm asm processing
            token := shr(32, calldataload(args.offset))
        }
    }
}

/// @title Controls
/// @dev A set of functions for executing hooks in the SwapVM protocol
/// It manages the program counter and executes hooks based on the current state
contract Controls {
    using ContextLib for Context;
    using ControlsArgsBuilder for bytes;

    error JumpMissingNextPCArg();
    error ControlsMissingTokenArg();
    error ControlsMissingMinAmountArg();
    error ControlsMissingMinShareArg();
    error ControlsMissingDeadlineArg();

    error DeadlineReached(address taker, uint256 deadline);
    error TakerTokenBalanceIsZero(address taker, address token);
    error TakerTokenBalanceIsLessThanRequired(address taker, address token, uint256 balance, uint256 minAmount);
    error TakerTokenBalanceSupplyShareIsLessThanRequired(address taker, address token, uint256 balance, uint256 totalSupply, uint256 minShareE18);

    /// @dev This instruction does nothing and can be used for uniqueness order hash value.
    function _salt(Context memory /* ctx */, bytes calldata /* args */) internal pure { }

    /// @dev Unconditional jump to the specified program counter
    /// @dev LIMITATION: Jump targets are limited to uint16 (0-65,535) due to 2-byte encoding.
    ///      For jumps to positions >= 65,536, use Extruction with custom control flow logic.
    /// @param args.nextPC | 2 bytes (uint16)
    function _jump(Context memory ctx, bytes calldata args) internal pure {
        uint256 nextPC = args.parseJump();
        ctx.setNextPC(nextPC);
    }

    /// @dev Jumps if tokenIn is the specified token
    /// @dev LIMITATION: Jump targets limited to uint16 (0-65,535). See _jump for details.
    /// @param args.token  | 20 bytes
    /// @param args.nextPC | 2 bytes (uint16)
    function _jumpIfTokenIn(Context memory ctx, bytes calldata args) internal pure {
        (address token, uint256 nextPC) = args.parseJumpIfToken();
        if (token == ctx.query.tokenIn) ctx.setNextPC(nextPC);
    }

    /// @dev Jumps if tokenOut is the specified token
    /// @dev LIMITATION: Jump targets limited to uint16 (0-65,535). See _jump for details.
    /// @param args.token  | 20 bytes
    /// @param args.nextPC | 2 bytes (uint16)
    function _jumpIfTokenOut(Context memory ctx, bytes calldata args) internal pure {
        (address token, uint256 nextPC) = args.parseJumpIfToken();
        if (token == ctx.query.tokenOut) ctx.setNextPC(nextPC);
    }

    /// @dev Reverts if the deadline has been reached
    /// @param args.deadline | 5 bytes
    function _deadline(Context memory ctx, bytes calldata args) internal view {
        uint256 deadline = args.parseDeadline();
        require(block.timestamp <= deadline, DeadlineReached(ctx.query.taker, deadline));
    }

    /// @dev Checks if the taker holds any amount of the specified token (NFTs are natively supported)
    /// @param args.token | 20 bytes
    function _onlyTakerTokenBalanceNonZero(Context memory ctx, bytes calldata args) internal view {
        address token = args.parseTakerTokenBalanceNonZero();
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
    }

    /// @dev Checks if the taker holds at least a certain amount of tokens
    /// @param args.token     | 20 bytes
    /// @param args.minAmount | 32 bytes
    function _onlyTakerTokenBalanceGte(Context memory ctx, bytes calldata args) internal view {
        (address token, uint256 minAmount) = args.parseTakerTokenBalanceGte();
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance >= minAmount, TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token, balance, minAmount));
    }

    /// @dev Checks if the taker holds at least a certain share of the total token supply
    /// @param args.token       | 20 bytes
    /// @param args.minShareE18 | 8 bytes
    function _onlyTakerTokenSupplyShareGte(Context memory ctx, bytes calldata args) internal view {
        (address token, uint256 minShareE18) = args.parseTakerTokenSupplyShareGte();
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        uint256 totalSupply = IERC20(token).totalSupply();
        // balance * 1e18 / totalSupply >= minShareE18
        require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply, TakerTokenBalanceSupplyShareIsLessThanRequired(ctx.query.taker, token, balance, totalSupply, minShareE18));
    }
}
