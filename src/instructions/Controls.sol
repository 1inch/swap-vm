// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Calldata } from "../libs/Calldata.sol";
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
        return abi.encodePacked(uint80(uint160(address(token))), nextPC);
    }

    function buildDeadline(uint40 deadline) internal pure returns (bytes memory) {
        return abi.encodePacked(deadline);
    }

    function buildTakerTokenBalanceNonZero(address token) internal pure returns (bytes memory) {
        return abi.encodePacked(token);
    }

    function buildTakerTokenBalanceGte(address token, uint256 minAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(token, minAmount);
    }

    function buildTakerTokenSupplyShareGte(address token, uint64 minShareE18) internal pure returns (bytes memory) {
        return abi.encodePacked(token, minShareE18);
    }
}

/// @title Controls
/// @dev A set of functions for executing hooks in the SwapVM protocol
/// It manages the program counter and executes hooks based on the current state
contract Controls {
    using Calldata for bytes;
    using ContextLib for Context;

    error JumpMissingNextPCArg();
    error ControlsMissingTokenArg();
    error ControlsMissingMinAmountArg();
    error ControlsMissingMinShareArg();
    error ControlsMissingDeadlineArg();

    error DeadlineReached(address taker, uint256 deadline);
    error TakerTokenBalanceIsZero(address maker, address token);
    error TakerTokenBalanceIsLessThatRequired(address maker, address token, uint256 balance, uint256 minAmount);
    error TakerTokenBalanceSupplyShareIsLessThatRequired(address maker, address token, uint256 balance, uint256 totalSupply, uint256 minShareE18);

    /// @dev This instruction does nothing and can be used for uniqueness order hash value.
    function _salt(Context memory /* ctx */, bytes calldata /* args */) internal pure { }

    /// @dev Unconditional jump to the specified program counter
    /// @param args.nextPC | 2 bytes
    function _jump(Context memory ctx, bytes calldata args) internal pure {
        uint256 nextPC = uint16(bytes2(args.slice(0, 2, JumpMissingNextPCArg.selector)));
        ctx.setNextPC(nextPC);
    }

    /// @dev Jumps if tokenIn is the specified token
    /// @param args.tokenTail | 10 bytes
    /// @param args.nextPC    | 2 bytes
    function _jumpIfTokenIn(Context memory ctx, bytes calldata args) internal pure {
        uint80 tokenTail = uint80(bytes10(args.slice(0, 10, ControlsMissingTokenArg.selector)));
        if (tokenTail == uint80(uint160(ctx.query.tokenIn))) {
            uint256 nextPC = uint16(bytes2(args.slice(10, 12, JumpMissingNextPCArg.selector)));
            ctx.setNextPC(nextPC);
        }
    }

    /// @dev Jumps if tokenOut is the specified token
    /// @param args.tokenTail | 10 bytes
    /// @param args.nextPC    | 2 bytes
    function _jumpIfTokenOut(Context memory ctx, bytes calldata args) internal pure {
        uint80 tokenTail = uint80(bytes10(args.slice(0, 10, ControlsMissingTokenArg.selector)));
        if (tokenTail == uint80(uint160(ctx.query.tokenOut))) {
            uint256 nextPC = uint16(bytes2(args.slice(10, 12, JumpMissingNextPCArg.selector)));
            ctx.setNextPC(nextPC);
        }
    }

    /// @dev Reverts if the deadline has been reached
    /// @param args.deadline | 5 bytes
    function _deadline(Context memory ctx, bytes calldata args) internal view {
        uint256 deadline = uint40(bytes5(args.slice(0, 5, ControlsMissingDeadlineArg.selector)));
        require(block.timestamp <= deadline, DeadlineReached(ctx.query.taker, deadline));
    }

    /// @dev Checks if the taker holds any amount of the specified token (NFTs are natively supported)
    /// @param args.token | 20 bytes
    function _onlyTakerTokenBalanceNonZero(Context memory ctx, bytes calldata args) internal view {
        address token = address(uint160(bytes20(args.slice(0, 20, ControlsMissingTokenArg.selector))));
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
    }

    /// @dev Checks if the taker holds at least a certain amount of tokens
    /// @param args.token     | 20 bytes
    /// @param args.minAmount | 32 bytes
    function _onlyTakerTokenBalanceGte(Context memory ctx, bytes calldata args) internal view {
        address token = address(uint160(bytes20(args.slice(0, 20, ControlsMissingTokenArg.selector))));
        uint256 minAmount = uint256(bytes32(args.slice(20, 52, ControlsMissingMinAmountArg.selector)));
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance >= minAmount, TakerTokenBalanceIsLessThatRequired(ctx.query.taker, token, balance, minAmount));
    }

    /// @dev Checks if the taker holds at least a certain share of the total token supply
    /// @param args.token       | 20 bytes
    /// @param args.minShareE18 | 8 bytes
    function _onlyTakerTokenSupplyShareGte(Context memory ctx, bytes calldata args) internal view {
        address token = address(uint160(bytes20(args.slice(0, 20, ControlsMissingTokenArg.selector))));
        uint256 minShareE18 = uint64(bytes8(args.slice(20, 28, ControlsMissingMinShareArg.selector)));
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        uint256 totalSupply = IERC20(token).totalSupply();
        // balance * 1e18 / totalSupply >= minShareE18
        require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply, TakerTokenBalanceSupplyShareIsLessThatRequired(ctx.query.taker, token, balance, totalSupply, minShareE18));
    }
}
