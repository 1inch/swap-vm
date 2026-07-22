// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

/// @notice Encoded fee receiver and fee percentages
type FeeReceiver is uint256;

library FeeReceiverLib {
    uint256 constant BPS = 1e7;

    function encode(address receiver, uint24 feeBps, uint24 surplusBps) internal pure returns (FeeReceiver) {
        return FeeReceiver.wrap((uint256(uint160(receiver)) << 96) | (uint256(feeBps) << 24) | surplusBps);
    }

    function decodeReceiver(FeeReceiver data) internal pure returns (address) {
        return address(uint160(FeeReceiver.unwrap(data) >> 96));
    }

    function decodeFeeBps(FeeReceiver data) internal pure returns (uint24) {
        return uint24(FeeReceiver.unwrap(data) >> 24);
    }

    function decodeSurplusBps(FeeReceiver data) internal pure returns (uint24) {
        return uint24(FeeReceiver.unwrap(data));
    }

    function resolveIn(FeeReceiver data, uint256 amount, uint256 surplus) internal pure returns (address receiver, uint256 fee) {
        uint24 feeBps = decodeFeeBps(data);
        uint24 surplusBps = decodeSurplusBps(data);
        return (decodeReceiver(data), amount * feeBps / BPS + surplus * surplusBps / BPS);
    }

    function resolveOut(FeeReceiver data, uint256 amount, uint24 totalBps, uint256 surplus) internal pure returns (address receiver, uint256 fee) {
        uint24 feeBps = decodeFeeBps(data);
        uint24 surplusBps = decodeSurplusBps(data);
        return (decodeReceiver(data), amount * feeBps / (BPS - totalBps) + surplus * surplusBps / BPS);
    }

    function init() internal pure returns (FeeReceiver[] memory array) { }
}

/// @notice Encoded fee receivers count, token to pay fee in flag, fee details
type FeeMeta is uint256;

library FeeMetaLib {
    using SafeERC20 for IERC20;

    function init() internal pure returns (FeeMeta) {
        return FeeMeta.wrap(0);
    }

    function encode(bool isTokenIn, uint8 count, uint24 totalBps, uint216 estimated) internal pure returns (FeeMeta) {
        return FeeMeta.wrap((uint256(estimated) << 40) | (uint256(totalBps) << 16) | (isTokenIn ? 256 : 0) | count);
    }

    function decodeIsTokenIn(FeeMeta data) internal pure returns (bool) {
        return (FeeMeta.unwrap(data) & 256) == 256;
    }

    function decodeIsTokenOut(FeeMeta data) internal pure returns (bool) {
        return (FeeMeta.unwrap(data) & 256) == 0;
    }

    function decodeCount(FeeMeta data) internal pure returns (uint8) {
        return uint8(FeeMeta.unwrap(data));
    }

    function decodeTotalBps(FeeMeta data) internal pure returns (uint24) {
        return uint24(FeeMeta.unwrap(data) >> 16);
    }

    function decodeSurplusEstimate(FeeMeta data) internal pure returns (uint216) {
        return uint216(FeeMeta.unwrap(data) >> 40);
    }

    function resolveInSafeTransfer(
        FeeMeta data,
        FeeReceiver[] memory receivers,
        address tokenIn,
        uint256 amountIn
    ) internal returns (uint256 totalFee) {
        uint8 count = decodeCount(data);
        bool isTokenIn = decodeIsTokenIn(data);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(data);
        uint256 totalFeeMax = amountIn * totalBps / FeeReceiverLib.BPS;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(data);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolveIn(receivers[--count], amountIn, surplusIn);
            totalFee += fee;

            IERC20(tokenIn).safeTransfer(receiver, fee);
        }
    }

    function resolveInAquaPullMaker(
        FeeMeta data,
        FeeReceiver[] memory receivers,
        address tokenIn,
        uint256 amountIn,
        IAqua aqua,
        address maker,
        bytes32 orderHash
    ) internal returns (uint256 totalFee) {
        uint8 count = decodeCount(data);
        bool isTokenIn = decodeIsTokenIn(data);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(data);
        uint256 totalFeeMax = amountIn * totalBps / FeeReceiverLib.BPS;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(data);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolveIn(receivers[--count], amountIn, surplusIn);
            totalFee += fee;

            aqua.pull(maker, orderHash, tokenIn, fee, receiver);
        }
    }

    function resolveInSafeTransferFromTaker(
        FeeMeta data,
        FeeReceiver[] memory receivers,
        address tokenIn,
        uint256 amountIn,
        address taker
    ) internal returns (uint256 totalFee) {
        uint8 count = decodeCount(data);
        bool isTokenIn = decodeIsTokenIn(data);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(data);
        uint256 totalFeeMax = amountIn * totalBps / FeeReceiverLib.BPS;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(data);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolveIn(receivers[--count], amountIn, surplusIn);
            totalFee += fee;

            IERC20(tokenIn).safeTransferFrom(taker, receiver, fee);
        }
    }

    function resolveOutAquaPullMaker(
        FeeMeta data,
        FeeReceiver[] memory receivers,
        address tokenOut,
        uint256 amountOut,
        IAqua aqua,
        address maker,
        bytes32 orderHash
    ) internal returns (uint256 totalFee) {
        uint8 count = decodeCount(data);
        bool isTokenOut = decodeIsTokenOut(data);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(data);
        uint256 totalFeeMax = amountOut * totalBps / (FeeReceiverLib.BPS - totalBps);

        uint256 surplusOut;
        uint256 estimatedOut = decodeSurplusEstimate(data);
        uint256 realOut = amountOut + totalFeeMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;
        else surplusOut = 0;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolveOut(receivers[--count], amountOut, totalBps, surplusOut);
            totalFee += fee;

            aqua.pull(maker, orderHash, tokenOut, fee, receiver);
        }
    }

    function resolveOutSafeTransferFromMaker(
        FeeMeta data,
        FeeReceiver[] memory receivers,
        address tokenOut,
        uint256 amountOut,
        address maker
    ) internal returns (uint256 totalFee) {
        uint8 count = decodeCount(data);
        bool isTokenOut = decodeIsTokenOut(data);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(data);
        uint256 totalFeeMax = amountOut * totalBps / (FeeReceiverLib.BPS - totalBps);

        uint256 surplusOut;
        uint256 estimatedOut = decodeSurplusEstimate(data);
        uint256 realOut = amountOut + totalFeeMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;
        else surplusOut = 0;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolveOut(receivers[--count], amountOut, totalBps, surplusOut);
            totalFee += fee;

            IERC20(tokenOut).safeTransferFrom(maker, receiver, fee);
        }
    }
}
