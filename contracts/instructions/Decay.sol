// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice Decay opcode, increase balance in and decrease balance out by offsets decaying over time since last trade
///   Offsets are increased at each swap by amount in and amount out against the current swap direction,
///   making immediate counter-swap have a worse price
/// @dev Encoding: [uint16 period]
/// @dev The opcode is expected to be executed only once in strategy flow, storage vars are written by the first-met opcode instance
library Decay {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    Opcode constant opcode = Opcode.Decay;

    function sizeOf(uint16) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 2;
    }

    function build(uint16 period) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(period)), period).resolve();
    }

    function build(MemoryPtr ptrStart, uint16 period) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(period, 2);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = args.at(0).asU16();
    }

    /// @dev Swap volumes for a single token.
    struct TokenVolumes {
        /// @dev Volume of token when it was swapped as token in.
        DecayVolume asTokenIn;
        /// @dev Volume of token when it was swapped as token out.
        DecayVolume asTokenOut;
    }

    struct OrderTokenVolumes {
        /// @dev Volumes for order token A.
        TokenVolumes tokenA;
        /// @dev Volumes for order token B.
        TokenVolumes tokenB;
    }

    struct Storage {
        mapping(bytes32 orderHash => OrderTokenVolumes) orderTokenVolumes;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        OrderTokenVolumes storage volumes = $.orderTokenVolumes[ctx.query.orderHash];

        TokenVolumes storage volumeTokenIn;
        TokenVolumes storage volumeTokenOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (volumeTokenIn, volumeTokenOut) = (volumes.tokenA, volumes.tokenB);
        else (volumeTokenIn, volumeTokenOut) = (volumes.tokenB, volumes.tokenA);

        ctx.swap.balanceIn += remainingVolume(volumeTokenIn.asTokenOut, period);
        ctx.swap.balanceOut -= remainingVolume(volumeTokenOut.asTokenIn, period);

        uint216 volumeIn = remainingVolume(volumeTokenIn.asTokenIn, period);
        uint216 volumeOut = remainingVolume(volumeTokenOut.asTokenOut, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        volumeIn += amountIn.toUint216();
        volumeOut += amountOut.toUint216();

        if (!ctx.vm.isStaticContext) {
            volumeTokenIn.asTokenIn = DecayVolumeLib.encode(volumeIn, uint40(block.timestamp));
            volumeTokenOut.asTokenOut = DecayVolumeLib.encode(volumeOut, uint40(block.timestamp));
        }
    }

    /// @dev Decay volume decreases linearly over time. Returns the remaining volume after given period.
    function remainingVolume(DecayVolume data, uint16 period) internal view returns (uint216) {
        unchecked {
            (uint216 volume, uint40 ts) = DecayVolumeLib.decode(data);

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return 0;
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return uint216(volume * timeLeft / period);
        }
    }
}

type DecayVolume is uint256;

library DecayVolumeLib {
    function encode(uint216 volume, uint40 ts) internal pure returns (DecayVolume) {
        return DecayVolume.wrap((uint256(volume) << 40) | ts);
    }

    function decode(DecayVolume data) internal pure returns (uint216 volume, uint40 ts) {
        return (uint216(DecayVolume.unwrap(data) >> 40), uint40(DecayVolume.unwrap(data)));
    }
}
