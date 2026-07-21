// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IProtocolFeeProvider } from "./interfaces/IProtocolFeeProvider.sol";

import { Context, ContextLib } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { FeeReceiver, FeeReceiverLib, FeeMetaLib } from "../libs/ProtocolFee.sol";

/// @notice FeeProtocol opcode, third-party fees resolved during the transfers phase
/// @dev Flat percent fee is payed by taker
///   Fee in token in is added to amount in, fee in token out is charged from amount out
/// @dev Surplus fee is payed by maker
///   Estimated amount in / out is linearly scaled to the swap amount
///   In case amount in exceeds or amount out inferiors the estimation, the difference is subject to surplus fee
/// @dev Encoding: [uint8 header, [uint8 flags, address target, uint24 feeBps?, uint24 surplusBps?] * count, uint216 surplusEstimate?]
///   header: [bit isTokenIn, bit3 _, uint4 count]
///   flags: [bit isProvider, bit takeFlatFee, bit takeSurplusFee, bit5 _]
///   feeBps is encoded if corresponding takeFlatFee flag is set and isProvider flag is not set
///   surplusBps is encoded if corresponding takeSurplusFee flag is set and isProvider flag is not set
///   surplusEstimate is encoded if any of takeSurplusFee flags is set
/// @dev The opcode is expected to be executed only once in strategy flow, fee registers are written by the first-met opcode instance
library FeeProtocol {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using ContextLib for Context;
    using Math for uint256;
    using SafeCast for uint256;

    error FeeProtocolNoFeeFlagsSet();
    error FeeProtocolBadTarget();
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

    function build(
        bool isTokenIn,
        ReceiverConfig[] memory receivers,
        ProviderConfig[] memory providers,
        uint216 surplusEstimate
    ) internal pure returns (bytes memory) {
        uint256 count = receivers.length + providers.length;
        require(count < 16, FeeProtocolExceedMaxCount());

        bytes memory args = abi.encodePacked(InstructionBuilder.encodeBool(isTokenIn, 0) | uint8(count));
        bool encodeSurplusEstimate;

        for (uint256 i; i < receivers.length; i++) {
            bool takeFlatFee = receivers[i].feeBps > 0;
            bool takeSurplusFee = receivers[i].surplusBps > 0;

            require(takeFlatFee || takeSurplusFee, FeeProtocolNoFeeFlagsSet());
            require(receivers[i].receiver != address(0), FeeProtocolBadTarget());

            args = abi.encodePacked(
                args,
                InstructionBuilder.encodeBool(false, 0) |
                InstructionBuilder.encodeBool(takeFlatFee, 1) |
                InstructionBuilder.encodeBool(takeSurplusFee, 2),
                receivers[i].receiver
            );

            if (takeFlatFee) args = abi.encodePacked(args, receivers[i].feeBps);
            if (takeSurplusFee) args = abi.encodePacked(args, receivers[i].surplusBps);

            encodeSurplusEstimate = encodeSurplusEstimate || takeSurplusFee;
        }

        for (uint256 i; i < providers.length; i++) {
            bool takeFlatFee = providers[i].takeFlatFee;
            bool takeSurplusFee = providers[i].takeSurplusFee;

            require(takeFlatFee || takeSurplusFee, FeeProtocolNoFeeFlagsSet());
            require(providers[i].provider != address(0), FeeProtocolBadTarget());

            args = abi.encodePacked(
                args,
                InstructionBuilder.encodeBool(true, 0) |
                InstructionBuilder.encodeBool(takeFlatFee, 1) |
                InstructionBuilder.encodeBool(takeSurplusFee, 2),
                providers[i].provider
            );

            encodeSurplusEstimate = encodeSurplusEstimate || takeSurplusFee;
        }

        if (encodeSurplusEstimate) args = abi.encodePacked(args, surplusEstimate);

        return InstructionBuilder.build(opcode, args);
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

    function parseSurplusEstimated(bytes calldata args, uint256 shift) internal pure returns (uint216 estimated) {
        estimated = args.at(shift).asU216();
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

                if (takeFlatFee) {
                    feeBps = parseFeeBps(args, shift);
                    unchecked { shift += 3; }
                }
                if (takeSurplusFee) {
                    surplusBps = parseFeeBps(args, shift);
                    unchecked { shift += 3; }
                }
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

        uint256 surplusEstimate;

        // Using floor division, protocol fees should not be rapacious
        if (isTokenIn) {
            if (ctx.query.isExactIn) {
                uint256 fee = ctx.swap.amountIn * totalFeeBps / BPS;

                ctx.swap.amountIn -= fee;
                ctx.runLoop();
                ctx.swap.amountIn += fee;
            } else {
                ctx.runLoop();

                uint256 fee = ctx.swap.amountIn * totalFeeBps / (BPS - totalFeeBps);
                ctx.swap.amountIn += fee;
            }

            if (totalSurplusBps > 0) {
                // Using ceil division favors maker
                uint256 estimatedIn = parseSurplusEstimated(args, shift);
                surplusEstimate = (estimatedIn * ctx.swap.amountOut).ceilDiv(ctx.swap.balanceOut);
            }
        } else {
            if (ctx.query.isExactIn) {
                ctx.runLoop();

                uint256 fee = ctx.swap.amountOut * totalFeeBps / BPS;
                ctx.swap.amountOut -= fee;
            } else {
                uint256 fee = ctx.swap.amountOut * totalFeeBps / (BPS - totalFeeBps);

                ctx.swap.amountOut += fee;
                ctx.runLoop();
                ctx.swap.amountOut -= fee;
            }

            if (totalSurplusBps > 0) {
                // Using floor division favors maker
                uint256 estimatedOut = parseSurplusEstimated(args, shift);
                surplusEstimate = estimatedOut * ctx.swap.amountIn / ctx.swap.balanceIn;
            }
        }

        ctx.fee.meta = FeeMetaLib.encode(isTokenIn, count, uint24(totalFeeBps), surplusEstimate.toUint216());
        ctx.fee.receivers = receivers;
    }
}
