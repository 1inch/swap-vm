// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library DecayArgsBuilder {
    using Calldata for bytes;

    error DecayMissingPeriodArg();

    function build(uint16 decayPeriod) internal pure returns (bytes memory) {
        return abi.encodePacked(decayPeriod);
    }

    function parse(bytes calldata args) internal pure returns (uint16 period) {
        period = uint16(bytes2(args.slice(0, 2, DecayMissingPeriodArg.selector)));
    }
}

struct DecayingOffset {
    uint216 offset;
    uint40 timestamp;
}

library DecayingOffsetLib {
    using SafeCast for uint256;

    function addOffset(DecayingOffset storage self, uint256 offset, uint256 decayPeriod) internal {
        _store(self, (getOffset(self, decayPeriod) + offset).toUint216(), uint40(block.timestamp));
    }

    function getOffset(DecayingOffset storage self, uint256 decayPeriod) internal view returns (uint256) {
        (uint216 offset, uint40 time) = _load(self);
        uint256 expiration = time + decayPeriod;
        if (block.timestamp >= expiration) {
            return 0;
        }
        uint256 timeLeft = expiration - block.timestamp;
        return offset * timeLeft / decayPeriod;
    }

    /// @dev Assembly implementation to make sure exactly 1 SLOAD is being used
    function _load(DecayingOffset storage balance) private view returns (uint216 offset, uint40 time) {
        assembly ("memory-safe") {
            let packed := sload(balance.slot)
            offset := and(packed, 0x0000000000ffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            time := shr(216, packed)
        }
    }

    /// @dev Assembly implementation to make sure exactly 1 SSTORE is being used
    function _store(DecayingOffset storage balance, uint216 offset, uint40 time) private {
        assembly ("memory-safe") {
            let packed := or(offset, shl(216, time))
            sstore(balance.slot, packed)
        }
    }
}

/// @dev You can to call _decayXD to readjust balanceIn/Out for swap
contract Decay {
    using ContextLib for Context;
    using DecayingOffsetLib for DecayingOffset;

    error DecayApplySwapAmountsRequiresAmountsToBeComputed(uint256 amountIn, uint256 amountOut);
    error DecayShouldBeCalledBeforeSwapAmountsComputation(uint256 amountIn, uint256 amountOut);

    /// @dev Offsets for balances in both directions: _offsets[orderHash][token][swapDirection]
    /// Should work for multi-token systems, swapDirection would mean buy/sell
    mapping(bytes32 orderHash =>
        mapping(address token =>
            mapping(bool buyOrSell => DecayingOffset))) internal _offsets;

    /// @param args.period | 2 bytes (uint16)
    function _decayXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, DecayShouldBeCalledBeforeSwapAmountsComputation(ctx.swap.amountIn, ctx.swap.amountOut));

        // Adjust balances by decayed offsets
        uint256 period = DecayArgsBuilder.parse(args);
        ctx.swap.balanceIn += _offsets[ctx.query.orderHash][ctx.query.tokenIn][true].getOffset(period);
        ctx.swap.balanceOut -= _offsets[ctx.query.orderHash][ctx.query.tokenOut][false].getOffset(period);

        (uint256 swapAmountIn, uint256 swapAmountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            _offsets[ctx.query.orderHash][ctx.query.tokenIn][false].addOffset(swapAmountIn, period);
            _offsets[ctx.query.orderHash][ctx.query.tokenOut][true].addOffset(swapAmountOut, period);
        }
    }
}
