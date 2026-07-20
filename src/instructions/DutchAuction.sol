// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { Power } from "../libs/Power.sol";

/// @notice DutchAuctionBalanceIn opcode, applies exponential decay to balance in (maker exact in)
///   Reverts after duration passes
/// @dev Encoding: [uint40 start, uint16 duration, uint64 decay]
/// @dev Should not be used with InvalidateTokenIn because it relies on balance in which is modified here
library DutchAuctionBalanceIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Power for uint256;

    error DutchAuctionWrongDecayFactor(uint64 decay);
    error DutchAuctionExpired(uint256 currentTime, uint256 deadline);

    Opcode constant opcode = Opcode.DutchAuctionBalanceIn;

    function build(uint40 start, uint16 duration, uint64 decay) internal pure returns (bytes memory) {
        require(decay < 1e18, DutchAuctionWrongDecayFactor(decay));

        bytes memory args = abi.encodePacked(start, duration, decay);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint40 start, uint16 duration, uint64 decay) {
        start = args.at(0).asU40();
        duration = args.at(5).asU16();
        decay = args.at(7).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint40 start, uint16 duration, uint64 decay) = parse(args);

        require(block.timestamp <= start + duration, DutchAuctionExpired(block.timestamp, start + duration));
        uint256 elapsed = block.timestamp - start;

        ctx.swap.balanceIn = ctx.swap.balanceIn * uint256(decay).pow(elapsed, 1e18) / 1e18;
    }
}

/// @notice DutchAuctionBalanceOut opcode, applies exponential growth to balance out (maker exact out)
///   Reverts after duration passes
/// @dev Encoding: [uint40 start, uint16 duration, uint64 decay]
///   Inverse exponential factor encoded `growth = 1 / decay`
/// @dev Should not be used with InvalidateTokenOut because it relies on balance out which is modified here
library DutchAuctionBalanceOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Power for uint256;

    error DutchAuctionWrongDecayFactor(uint64 decay);
    error DutchAuctionExpired(uint256 currentTime, uint256 deadline);

    Opcode constant opcode = Opcode.DutchAuctionBalanceOut;

    function build(uint40 start, uint16 duration, uint64 decay) internal pure returns (bytes memory) {
        require(decay < 1e18, DutchAuctionWrongDecayFactor(decay));

        bytes memory args = abi.encodePacked(start, duration, decay);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint40 start, uint16 duration, uint64 decay) {
        start = args.at(0).asU40();
        duration = args.at(5).asU16();
        decay = args.at(7).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint40 start, uint16 duration, uint64 decay) = parse(args);

        require(block.timestamp <= start + duration, DutchAuctionExpired(block.timestamp, start + duration));
        uint256 elapsed = block.timestamp - start;

        ctx.swap.balanceOut = ctx.swap.balanceOut * 1e18 / uint256(decay).pow(elapsed, 1e18);
    }
}
