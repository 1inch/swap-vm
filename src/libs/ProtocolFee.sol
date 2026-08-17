// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ProtocolFee } from "./VM.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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

    function resolve(FeeReceiver data, uint256 amount, uint24 totalBps, uint256 surplus) internal pure returns (address receiver, uint256 fee) {
        uint24 feeBps = decodeFeeBps(data);
        uint24 surplusBps = decodeSurplusBps(data);

        receiver = decodeReceiver(data);
        if (feeBps > 0) fee += amount * feeBps / totalBps;
        fee += surplus * surplusBps / BPS;
    }

    function init() internal pure returns (FeeReceiver[] memory array) { }
}

/// @notice Encoded fee receivers count, token to pay fee in flag, fee details
type FeeMeta is uint256;

library FeeMetaLib {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error FeeMetaSurplusScaleUp();

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

    function scaleSurplusEstimate(FeeMeta data, uint256 num, uint256 denom) internal pure returns (FeeMeta) {
        require(num <= denom, FeeMetaSurplusScaleUp()); // Allow decrease-only scaling

        bool isTokenIn = decodeIsTokenIn(data);
        uint256 estimated = decodeSurplusEstimate(data);

        // Round favor maker
        if (isTokenIn) estimated = (estimated * num).ceilDiv(denom);
        else estimated = estimated * num / denom;

        return FeeMeta.wrap((uint256(estimated) << 40) | (FeeMeta.unwrap(data) & type(uint40).max));
    }

    function resolveInSafeTransfer(
        ProtocolFee memory data,
        address tokenIn,
        uint256 amountIn
    ) internal returns (uint256 totalFee) {
        FeeMeta meta = data.meta;
        uint8 count = decodeCount(meta);
        bool isTokenIn = decodeIsTokenIn(meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(meta);
        uint256 totalFeeMax = data.feeTotal;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(meta);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeMax, totalBps, surplusIn);
            totalFee += fee;

            IERC20(tokenIn).safeTransfer(receiver, fee);
        }
    }

    function resolveInAquaPullMaker(
        ProtocolFee memory data,
        address tokenIn,
        uint256 amountIn,
        IAqua aqua,
        address maker,
        bytes32 orderHash
    ) internal returns (uint256 totalFee) {
        FeeMeta meta = data.meta;
        uint8 count = decodeCount(meta);
        bool isTokenIn = decodeIsTokenIn(meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(meta);
        uint256 totalFeeMax = data.feeTotal;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(meta);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeMax, totalBps, surplusIn);
            totalFee += fee;

            aqua.pull(maker, orderHash, tokenIn, fee, receiver);
        }
    }

    function resolveInSafeTransferFromTaker(
        ProtocolFee memory data,
        address tokenIn,
        uint256 amountIn,
        address taker
    ) internal returns (uint256 totalFee) {
        FeeMeta meta = data.meta;
        uint8 count = decodeCount(meta);
        bool isTokenIn = decodeIsTokenIn(meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(meta);
        uint256 totalFeeMax = data.feeTotal;

        uint256 surplusIn;
        uint256 estimatedIn = decodeSurplusEstimate(meta);
        uint256 realIn = amountIn - totalFeeMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeMax, totalBps, surplusIn);
            totalFee += fee;

            IERC20(tokenIn).safeTransferFrom(taker, receiver, fee);
        }
    }

    function resolveOutAquaPullMaker(
        ProtocolFee memory data,
        address tokenOut,
        uint256 amountOut,
        IAqua aqua,
        address maker,
        bytes32 orderHash
    ) internal returns (uint256 totalFee) {
        FeeMeta meta = data.meta;
        uint8 count = decodeCount(meta);
        bool isTokenOut = decodeIsTokenOut(meta);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(meta);
        uint256 totalFeeMax = data.feeTotal;

        uint256 surplusOut;
        uint256 estimatedOut = decodeSurplusEstimate(meta);
        uint256 realOut = amountOut + totalFeeMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;
        else surplusOut = 0;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeMax, totalBps, surplusOut);
            totalFee += fee;

            aqua.pull(maker, orderHash, tokenOut, fee, receiver);
        }
    }

    function resolveOutSafeTransferFromMaker(
        ProtocolFee memory data,
        address tokenOut,
        uint256 amountOut,
        address maker
    ) internal returns (uint256 totalFee) {
        FeeMeta meta = data.meta;
        uint8 count = decodeCount(meta);
        bool isTokenOut = decodeIsTokenOut(meta);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalBps = decodeTotalBps(meta);
        uint256 totalFeeMax = data.feeTotal;

        uint256 surplusOut;
        uint256 estimatedOut = decodeSurplusEstimate(meta);
        uint256 realOut = amountOut + totalFeeMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;
        else surplusOut = 0;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeMax, totalBps, surplusOut);
            totalFee += fee;

            IERC20(tokenOut).safeTransferFrom(maker, receiver, fee);
        }
    }
}
