// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice OnlyTakerTokenBalanceNonZero opcode, fail if taker token balance is zero (NFT-compatible)
/// @dev Encoding: [address token]
/// @dev Since EIP-7702, user may delegate it's account to certain code, potentially sharing
///   authorization given even by soulbound NFT with other users
library OnlyTakerTokenBalanceNonZero {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceIsZero(address taker, address token);

    Opcode constant opcode = Opcode.OnlyTakerTokenBalanceNonZero;

    function build(address token) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token) {
        token = args.at(0).asAddress();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        address token = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
    }
}

/// @notice OnlyTxOriginTokenBalanceNonZero opcode, fail if tx.origin token balance is zero (NFT-compatible)
///   The opcode allows authorized user to fill the order through 3rd-party contracts
/// @dev Encoding: [address token]
/// @dev Validations through tx.origin are considered weak due to possible transaction flow
///   interception: any contract executing tx originated from tx.origin can pass the validation
library OnlyTxOriginTokenBalanceNonZero {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TxOriginTokenBalanceIsZero(address txOrigin, address token);

    Opcode constant opcode = Opcode.OnlyTxOriginTokenBalanceNonZero;

    function build(address token) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token) {
        token = args.at(0).asAddress();
    }

    function exec(Context memory, bytes calldata args) internal view {
        address token = parse(args);
        uint256 balance = IERC20(token).balanceOf(tx.origin);
        require(balance > 0, TxOriginTokenBalanceIsZero(tx.origin, token));
    }
}

/// @notice OnlyTakerTokenBalanceGte opcode, fail if taker token balance is below expected value
/// @dev Encoding: [address token, uint256 amount]
library OnlyTakerTokenBalanceGte {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceIsLessThanRequired(address taker, address token, uint256 balance, uint256 amount);

    Opcode constant opcode = Opcode.OnlyTakerTokenBalanceGte;

    function build(address token, uint256 amount) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, amount);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint256 amount) {
        token = args.at(0).asAddress();
        amount = args.at(20).asU256();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (address token, uint256 amount) = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        require(balance >= amount, TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token, balance, amount));
    }
}

/// @notice OnlyTakerTokenSupplyShareGte opcode, fail if taker token share is below expected share
/// @dev Encoding: [address token, uint64 shareE18]
library OnlyTakerTokenSupplyShareGte {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error TakerTokenBalanceSupplyShareIsLessThanRequired(
        address taker, address token, uint256 balance, uint256 totalSupply, uint64 shareE18
    );

    Opcode constant opcode = Opcode.OnlyTakerTokenSupplyShareGte;

    function build(address token, uint64 shareE18) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(token, shareE18);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (address token, uint64 shareE18) {
        token = args.at(0).asAddress();
        shareE18 = args.at(20).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (address token, uint64 shareE18) = parse(args);
        uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
        uint256 totalSupply = IERC20(token).totalSupply();
        // balance * 1e18 / totalSupply >= minShareE18
        require(
            totalSupply > 0 && balance * 1e18 >= shareE18 * totalSupply,
            TakerTokenBalanceSupplyShareIsLessThanRequired(ctx.query.taker, token, balance, totalSupply, shareE18)
        );
    }
}
