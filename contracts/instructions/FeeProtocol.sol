// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IProtocolFeeProvider } from "./interfaces/IProtocolFeeProvider.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { FeeReceiver, FeeReceiverLib, FeeMetaLib } from "../libs/ProtocolFee.sol";

/// @notice FeeProtocol opcode, third-party fees resolved during the transfers phase
/// @dev Flat percent fee is payed by taker
///   Fee in token in is added to amount in, fee in token out is charged from amount out
/// @dev Surplus fee is payed by maker
///   Estimated amount in / out is set and scaled according to the amount-to-balance proportion by FeeProtocolSurplus opcode
///   In case amount in exceeds or amount out inferiors the estimation, the difference is subject to surplus fee
/// @dev Encoding: [uint8 header, bytes21 provider * providers.length, bytes27 receiver * receivers.length]
///   header: [bit isTokenIn, bit3 _, uint4 count]; count = providers.length + receivers.length
///   provider: [bit true, bit takeFlatFee, bit takeSurplusFee, bit5 _, address provider]
///   receiver: [bit false, bit7 _, address receiver, uint24 feeBps, uint24 surplusBps]
/// @dev The opcode is expected to be executed only once in strategy flow, fee registers are written by the first-met opcode instance
///   The opcode is expects FeeProtocolSurplus to be applied if any surplusBps or takeSurplusFee set
library FeeProtocol {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using SafeCast for uint256;

    error FeeProtocolExceedMaxCount();
    error FeeBpsOutOfRange(uint256 feeBps, uint256 surplusBps);

    Opcode constant opcode = Opcode.FeeProtocol;

    uint256 constant BPS = FeeReceiverLib.BPS;

    struct ReceiverConfig {
        address receiver;
        uint24 feeBps;
        uint24 surplusBps;
    }

    struct ProviderConfig {
        address provider;
        bool takeFlatFee;
        bool takeSurplusFee;
    }

    function sizeOf(bool, ReceiverConfig[] memory receivers, ProviderConfig[] memory providers) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + receivers.length * (1 + 20 + 6) + providers.length * (1 + 20);
    }

    function build(bool isTokenIn, ReceiverConfig[] memory receivers, ProviderConfig[] memory providers) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(isTokenIn, receivers, providers)), isTokenIn, receivers, providers).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool isTokenIn,
        ReceiverConfig[] memory receivers,
        ProviderConfig[] memory providers
    ) internal pure returns (MemoryPtr ptr) {
        uint256 count = receivers.length + providers.length;
        require(count <= 0x0f, FeeProtocolExceedMaxCount());

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(isTokenIn, 0) | uint8(count));

        for (uint256 i; i < providers.length; i++) {
            uint8 flags = InstructionBuilder.encodeBool(true, 0) |
                InstructionBuilder.encodeBool(providers[i].takeFlatFee, 1) |
                InstructionBuilder.encodeBool(providers[i].takeSurplusFee, 2);
            ptr = ptr.push(flags).push(providers[i].provider);
        }

        for (uint256 i; i < receivers.length; i++) {
            ptr = ptr.push(InstructionBuilder.encodeBool(false, 0)).push(receivers[i].receiver);
            ptr = ptr.push(receivers[i].feeBps, 3).push(receivers[i].surplusBps, 3);
        }

        ptrStart.patchLength(ptr);
    }

    function parseHeader(bytes calldata args) internal pure returns (bool isTokenIn, uint8 count) {
        isTokenIn = args.at(0).asBool(0);
        count = args.at(0).asU8() & 0x0f;
    }

    function parseItem(
        bytes calldata args,
        uint256 shift
    ) internal pure returns (bool isProvider, bool takeFlatFee, bool takeSurplusFee, address target) {
        isProvider = args.at(shift).asBool(0);
        takeFlatFee = args.at(shift).asBool(1);
        takeSurplusFee = args.at(shift).asBool(2);

        target = args.at(shift + 1).asAddress();
    }

    function parseFeeBps(bytes calldata args, uint256 shift) internal pure returns (uint24 feeBps) {
        feeBps = args.at(shift).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (bool isTokenIn, uint8 count) = parseHeader(args);
        uint256 shift = 1;

        FeeReceiver[] memory receivers = new FeeReceiver[](count);

        uint256 totalFeeBps;
        uint256 totalSurplusBps;

        uint256 i;
        while (i < count) {
            (bool isProvider, bool takeFlatFee, bool takeSurplusFee, address target) = parseItem(args, shift);
            unchecked { shift += 21; }

            address receiver;
            uint24 feeBps;
            uint24 surplusBps;
            if (isProvider) {
                (receiver, feeBps, surplusBps) = IProtocolFeeProvider(target).getRecipientAndFees(
                    ctx.query.orderHash,
                    ctx.query.maker,
                    ctx.query.taker,
                    ctx.query.tokenIn,
                    ctx.query.tokenOut,
                    ctx.query.isExactIn
                );

                if (!takeFlatFee) feeBps = 0;
                if (!takeSurplusFee) surplusBps = 0;
            } else {
                receiver = target;

                feeBps = parseFeeBps(args, shift);
                unchecked { shift += 3; }
                surplusBps = parseFeeBps(args, shift);
                unchecked { shift += 3; }
            }

            if (receiver == address(0) || (feeBps == 0 && surplusBps == 0)) {
                unchecked { count--; }
            } else {
                receivers[i] = FeeReceiverLib.encode(receiver, feeBps, surplusBps);
                unchecked {
                    totalFeeBps += feeBps;
                    totalSurplusBps += surplusBps;
                    i++;
                }
            }
        }

        require(totalFeeBps < BPS && totalSurplusBps < BPS, FeeBpsOutOfRange(totalFeeBps, totalSurplusBps));

        // Protocol fees rounded down
        // Reduce amounts for totalFeeBps once here, split totalFeeAmount across receivers at transfer phase
        uint256 totalFeeAmount;
        if (isTokenIn) {
            if (ctx.query.isExactIn) {
                totalFeeAmount = ctx.swap.amountIn * totalFeeBps / BPS;
                ctx.swap.amountIn -= totalFeeAmount;

                uint256 reduction = ctx.swap.amountIn;
                ctx.runLoop();
                reduction -= ctx.swap.amountIn;

                if (reduction > 0) totalFeeAmount = ctx.swap.amountIn * totalFeeBps / (BPS - totalFeeBps);
            } else {
                ctx.runLoop();
                totalFeeAmount = ctx.swap.amountIn * totalFeeBps / (BPS - totalFeeBps);
            }
            ctx.swap.amountIn += totalFeeAmount;
        } else {
            if (!ctx.query.isExactIn) ctx.swap.amountOut += ctx.swap.amountOut * totalFeeBps / (BPS - totalFeeBps);
            ctx.runLoop();
            totalFeeAmount = ctx.swap.amountOut * totalFeeBps / BPS;
            ctx.swap.amountOut -= totalFeeAmount;
        }

        if (totalFeeBps == 0) totalFeeBps = 1; // Avoid zero total bps for unconditional final receiver amounts calculation
        ctx.fee.meta = FeeMetaLib.encode(isTokenIn, count, uint24(totalFeeBps), totalFeeAmount.toUint216());
        ctx.fee.receivers = receivers;
    }
}

/// @notice FeeProtocolSurplus opcode, set maker total receive or spend estimation in addition to FeeProtocol which set receivers
/// @dev Encoding: [bool isTokenIn, uint256 estimated]
///   isTokenIn should match the flag set in FeeProtocol
/// @dev Supports only single direction swaps, scales estimation according to the amount-to-balance proportion
/// @dev The opcode is expected to be executed only once in strategy flow, fee registers are written by the first-met opcode instance
///   The opcode is expected to be applied before InvalidateTokenIn or InvalidateTokenOut to apply scaling properly
library FeeProtocolSurplus {
    using InstructionArgs for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    Opcode constant opcode = Opcode.FeeProtocolSurplus;

    function sizeOf(bool, uint256) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + 32;
    }

    function build(bool isTokenIn, uint256 estimated) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(isTokenIn, estimated)), isTokenIn, estimated).resolve();
    }

    function build(MemoryPtr ptrStart, bool isTokenIn, uint256 estimated) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(isTokenIn, 0)).push(estimated, 32);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool isTokenIn, uint256 estimated) {
        isTokenIn = args.at(0).asBool(0);
        estimated = args.at(1).asU256();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        (bool isTokenIn, uint256 estimated) = parse(args);

        if (isTokenIn) {
            uint256 balanceOut = ctx.swap.balanceOut;
            ctx.runLoop();

            // Estimated receive round up to shrink surplus fee
            ctx.fee.surplusEstimation = (estimated * ctx.swap.amountOut).ceilDiv(balanceOut);
        } else {
            uint256 balanceIn = ctx.swap.balanceIn;
            ctx.runLoop();

            // Estimated spend round down to shrink surplus fee
            ctx.fee.surplusEstimation = estimated * ctx.swap.amountIn / balanceIn;
        }
    }
}
