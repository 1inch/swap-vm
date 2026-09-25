// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { Power } from "../libs/Power.sol";
import { Time } from "../libs/Time.sol";

/// @notice DutchAuctionBalanceIn opcode, applies exponential decay to balance in (maker exact sell)
///   Max surcharge bps is specified; order balance in is the "maker receive at least" value
/// @dev Encoding: [uint40 start, uint64 decay, uint24 surchargeBps]
/// @dev Should not be used with InvalidateTokenIn because it relies on balance in which is modified here
library DutchAuctionBalanceIn {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using Power for uint256;

    error DutchAuctionWrongDecayFactor(uint64 decay);
    error DutchAuctionSurchargeOutOfRange(uint24 surchargeBps);

    Opcode constant opcode = Opcode.DutchAuctionBalanceIn;

    uint256 constant ONE = 1e18;
    uint256 constant BPS = 1e7;

    function sizeOf(uint40, uint64, uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 5 + 8 + 3;
    }

    function build(uint40 start, uint64 decay, uint24 surchargeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(start, decay, surchargeBps)), start, decay, surchargeBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 start, uint64 decay, uint24 surchargeBps) internal pure returns (MemoryPtr ptr) {
        require(decay < ONE, DutchAuctionWrongDecayFactor(decay));
        require(surchargeBps < BPS, DutchAuctionSurchargeOutOfRange(surchargeBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(start, 5).push(decay, 8).push(surchargeBps, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint40 start, uint64 decay, uint24 surchargeBps) {
        start = args.at(0).asU40();
        decay = args.at(5).asU64();
        surchargeBps = args.at(13).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (uint40 start, uint64 decay, uint24 surchargeBps) = parse(args);
        start = Time.resolve(ctx, start);

        uint256 elapsed = block.timestamp - start;
        uint256 balance = ctx.swap.balanceIn * (BPS + surchargeBps) * uint256(decay).pow(elapsed, ONE) / (ONE * BPS);
        if (balance <= ctx.swap.balanceIn) return;

        ctx.swap.surcharge += balance - ctx.swap.balanceIn;
        ctx.swap.balanceIn = balance;
    }
}

/// @notice DutchAuctionBalanceOut opcode, applies exponential growth to balance out (maker exact buy)
///   Max surcharge bps is specified; order balance out is the "maker spend at most" value
/// @dev Encoding: [uint40 start, uint64 decay, uint24 surchargeBps]
/// @dev Should not be used with InvalidateTokenOut because it relies on balance out which is modified here
library DutchAuctionBalanceOut {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;
    using Power for uint256;

    error DutchAuctionWrongDecayFactor(uint64 decay);
    error DutchAuctionSurchargeOutOfRange(uint24 surchargeBps);

    Opcode constant opcode = Opcode.DutchAuctionBalanceOut;

    uint256 constant ONE = 1e18;
    uint256 constant BPS = 1e7;

    function sizeOf(uint40, uint64, uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 5 + 8 + 3;
    }

    function build(uint40 start, uint64 decay, uint24 surchargeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(start, decay, surchargeBps)), start, decay, surchargeBps).resolve();
    }

    function build(MemoryPtr ptrStart, uint40 start, uint64 decay, uint24 surchargeBps) internal pure returns (MemoryPtr ptr) {
        require(decay < ONE, DutchAuctionWrongDecayFactor(decay));
        require(surchargeBps < BPS, DutchAuctionSurchargeOutOfRange(surchargeBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(start, 5).push(decay, 8).push(surchargeBps, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint40 start, uint64 decay, uint24 surchargeBps) {
        start = args.at(0).asU40();
        decay = args.at(5).asU64();
        surchargeBps = args.at(13).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (uint40 start, uint64 decay, uint24 surchargeBps) = parse(args);
        start = Time.resolve(ctx, start);

        uint256 elapsed = block.timestamp - start;
        uint256 balance = (ctx.swap.balanceOut * BPS * ONE).ceilDiv((BPS + surchargeBps) * uint256(decay).pow(elapsed, ONE));
        if (balance >= ctx.swap.balanceOut) return;

        ctx.swap.surcharge += ctx.swap.balanceOut - balance;
        ctx.swap.balanceOut = balance;
    }
}
