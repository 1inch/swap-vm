// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ProtocolFee } from "./VM.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Encoded fee receiver and fee percentages
/// @dev Encoding: [address receiver, bytes6 _, uint24 surplusBps, uint24 feeBps]
type FeeReceiver is uint256;

library FeeReceiverLib {
    uint256 constant BPS = 1e7;

    function encode(address receiver, uint24 feeBps, uint24 surplusBps) internal pure returns (FeeReceiver) {
        return FeeReceiver.wrap((uint256(uint160(receiver)) << 96) | (uint256(surplusBps) << 24) | feeBps);
    }

    function decodeReceiver(FeeReceiver data) internal pure returns (address) {
        return address(uint160(FeeReceiver.unwrap(data) >> 96));
    }

    function decodeFeeBps(FeeReceiver data) internal pure returns (uint24) {
        return uint24(FeeReceiver.unwrap(data));
    }

    function decodeSurplusBps(FeeReceiver data) internal pure returns (uint24) {
        return uint24(FeeReceiver.unwrap(data) >> 24);
    }

    /// @notice Calculate final receiver fee amount
    /// @dev Expects non-zero totalFeeBps
    function resolve(
        FeeReceiver data,
        uint256 totalFeeAmount,
        uint24 totalFeeBps,
        uint256 surplusAmount
    ) internal pure returns (address receiver, uint256 fee) {
        uint24 feeBps = decodeFeeBps(data);
        uint24 surplusBps = decodeSurplusBps(data);

        receiver = decodeReceiver(data);
        fee = totalFeeAmount * feeBps / totalFeeBps + surplusAmount * surplusBps / BPS;
    }

    /// @dev Real initialization is held by FeeProtocol opcode, zero-pointer for Context initialization
    function init() internal pure returns (FeeReceiver[] memory array) { }
}

/// @notice Encoded fee receivers count, token to pay fee in flag, maker expected spend / receive for surplus calculation
/// @dev Encoding: [uint216 totalFeeAmount, uint24 totalFeeBps, bool isTokenIn, uint8 count]
type FeeMeta is uint256;

library FeeMetaLib {
    function encode(bool isTokenIn, uint8 count, uint24 totalFeeBps, uint216 totalFeeAmount) internal pure returns (FeeMeta) {
        return FeeMeta.wrap((uint256(totalFeeAmount) << 40) | (uint256(totalFeeBps) << 16) | (isTokenIn ? 0 : 256) | count);
    }

    function decodeIsTokenIn(FeeMeta data) internal pure returns (bool) {
        return (FeeMeta.unwrap(data) & 256) == 0;
    }

    function decodeIsTokenOut(FeeMeta data) internal pure returns (bool) {
        return (FeeMeta.unwrap(data) & 256) == 256;
    }

    function decodeCount(FeeMeta data) internal pure returns (uint8) {
        return uint8(FeeMeta.unwrap(data));
    }

    function decodeTotalFeeBps(FeeMeta data) internal pure returns (uint24) {
        return uint24(FeeMeta.unwrap(data) >> 16);
    }

    function decodeTotalFeeAmount(FeeMeta data) internal pure returns (uint216) {
        return uint216(FeeMeta.unwrap(data) >> 40);
    }

    /// @dev Real initialization is held by FeeProtocol opcode, empty for Context initialization
    function init() internal pure returns (FeeMeta meta) { }
}

/// @notice Send fees during the transfers phase
/// @dev Split of totalFeeAmount by receivers may cause dust left, the dust goes to the maker
///   This might cause super-additive behavior at extremely low-liquidity AMM positions processing fees in token out
///   Surplus amount is decreased by the dust favoring maker
library ProtocolFeeLib {
    using SafeERC20 for IERC20;

    function resolveInSafeTransfer(
        ProtocolFee memory data,
        address tokenIn,
        uint256 amountIn
    ) internal returns (uint256 totalFee) {
        uint8 count = FeeMetaLib.decodeCount(data.meta);
        bool isTokenIn = FeeMetaLib.decodeIsTokenIn(data.meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalFeeBps = FeeMetaLib.decodeTotalFeeBps(data.meta);
        uint256 totalFeeAmountMax = FeeMetaLib.decodeTotalFeeAmount(data.meta);

        uint256 surplusIn;
        uint256 estimatedIn = data.surplusEstimation;
        uint256 realIn = amountIn - totalFeeAmountMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeAmountMax, totalFeeBps, surplusIn);
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
        uint8 count = FeeMetaLib.decodeCount(data.meta);
        bool isTokenIn = FeeMetaLib.decodeIsTokenIn(data.meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalFeeBps = FeeMetaLib.decodeTotalFeeBps(data.meta);
        uint256 totalFeeAmountMax = FeeMetaLib.decodeTotalFeeAmount(data.meta);

        uint256 surplusIn;
        uint256 estimatedIn = data.surplusEstimation;
        uint256 realIn = amountIn - totalFeeAmountMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeAmountMax, totalFeeBps, surplusIn);
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
        uint8 count = FeeMetaLib.decodeCount(data.meta);
        bool isTokenIn = FeeMetaLib.decodeIsTokenIn(data.meta);
        if (!isTokenIn || count == 0) return 0;

        uint24 totalFeeBps = FeeMetaLib.decodeTotalFeeBps(data.meta);
        uint256 totalFeeAmountMax = FeeMetaLib.decodeTotalFeeAmount(data.meta);

        uint256 surplusIn;
        uint256 estimatedIn = data.surplusEstimation;
        uint256 realIn = amountIn - totalFeeAmountMax;
        if (realIn > estimatedIn) surplusIn = realIn - estimatedIn;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeAmountMax, totalFeeBps, surplusIn);
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
        uint8 count = FeeMetaLib.decodeCount(data.meta);
        bool isTokenOut = FeeMetaLib.decodeIsTokenOut(data.meta);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalFeeBps = FeeMetaLib.decodeTotalFeeBps(data.meta);
        uint256 totalFeeAmountMax = FeeMetaLib.decodeTotalFeeAmount(data.meta);

        uint256 surplusOut;
        uint256 estimatedOut = data.surplusEstimation;
        uint256 realOut = amountOut + totalFeeAmountMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeAmountMax, totalFeeBps, surplusOut);
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
        uint8 count = FeeMetaLib.decodeCount(data.meta);
        bool isTokenOut = FeeMetaLib.decodeIsTokenOut(data.meta);
        if (!isTokenOut || count == 0) return 0;

        uint24 totalFeeBps = FeeMetaLib.decodeTotalFeeBps(data.meta);
        uint256 totalFeeAmountMax = FeeMetaLib.decodeTotalFeeAmount(data.meta);

        uint256 surplusOut;
        uint256 estimatedOut = data.surplusEstimation;
        uint256 realOut = amountOut + totalFeeAmountMax;
        if (estimatedOut > realOut) surplusOut = estimatedOut - realOut;

        while (count > 0) {
            (address receiver, uint256 fee) = FeeReceiverLib.resolve(data.receivers[--count], totalFeeAmountMax, totalFeeBps, surplusOut);
            totalFee += fee;

            IERC20(tokenOut).safeTransferFrom(maker, receiver, fee);
        }
    }
}
