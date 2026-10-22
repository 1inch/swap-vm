// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { Power } from "../libs/Power.sol";
import { Time } from "../libs/Time.sol";

/// @notice DutchAuction opcode, applies exponential time-decaying surcharge to balance in or balance out
/// @dev Encoding: [bool adjustIn, uint40 start, uint64 decay, uint24 surchargeBps]
/// @dev Should not be used with InvalidateTokenIn for `adjustIn = true` or InvalidateTokenOut for `adjustIn = false`
library DutchAuction {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;
    using Power for uint256;

    error DutchAuctionWrongDecayFactor(uint64 decay);
    error DutchAuctionSurchargeOutOfRange(uint24 surchargeBps);

    Opcode constant opcode = Opcode.DutchAuction;

    uint256 constant ONE = 1e18;
    uint256 constant BPS = 1e7;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + 5 + 8 + 3;
    }

    function build(bool adjustIn, uint40 start, uint64 decay, uint24 surchargeBps) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), adjustIn, start, decay, surchargeBps).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool adjustIn,
        uint40 start,
        uint64 decay,
        uint24 surchargeBps
    ) internal pure returns (MemoryPtr ptr) {
        require(decay < ONE, DutchAuctionWrongDecayFactor(decay));
        require(surchargeBps < BPS, DutchAuctionSurchargeOutOfRange(surchargeBps));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(adjustIn, 0)).push(start, 5).push(decay, 8).push(surchargeBps, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool adjustIn, uint40 start, uint64 decay, uint24 surchargeBps) {
        adjustIn = args.at(0).asBool(0);
        start = args.at(1).asU40();
        decay = args.at(6).asU64();
        surchargeBps = args.at(14).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (bool adjustIn, uint40 start, uint64 decay, uint24 surchargeBps) = parse(args);
        start = Time.resolve(ctx, start);

        uint256 elapsed = block.timestamp - start;
        uint256 factor = (BPS + surchargeBps) * uint256(decay).pow(elapsed, ONE);

        if (adjustIn) {
            uint256 balance = ctx.swap.balanceIn * factor / (ONE * BPS);
            if (balance <= ctx.swap.balanceIn) return;

            ctx.swap.surcharge += balance - ctx.swap.balanceIn;
            ctx.swap.balanceIn = balance;
        } else {
            if (factor == 0) return;

            uint256 balance = (ctx.swap.balanceOut * BPS * ONE).ceilDiv(factor);
            if (balance >= ctx.swap.balanceOut) return;

            ctx.swap.surcharge += ctx.swap.balanceOut - balance;
            ctx.swap.balanceOut = balance;
        }
    }
}
