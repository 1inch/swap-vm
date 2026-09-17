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

/// @notice Decay opcode, increase balance in and decrease balance out by virtual balances decaying over time since last trade
///   Virtual balances are increased at each swap by amount in and amount out against the current swap direction,
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

    /// @dev Virtual balances for a single token.
    struct TokenVirtualBalances {
        /// @dev Virtual balance when this token was swapped as token in.
        VirtualBalance asTokenIn;
        /// @dev Virtual balance when this token was swapped as token out.
        VirtualBalance asTokenOut;
    }

    struct OrderTokensVirtualBalances {
        /// @dev Virtual balances for order's token A.
        TokenVirtualBalances tokenA;
        /// @dev Virtual balances for order's token B.
        TokenVirtualBalances tokenB;
    }

    struct Storage {
        mapping(bytes32 orderHash => OrderTokensVirtualBalances) orderVirtualBalances;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.Decay;
        assembly ("memory-safe") { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        Storage storage $ = store();
        uint16 period = parse(args);

        OrderTokensVirtualBalances storage virtualBalances = $.orderVirtualBalances[ctx.query.orderHash];

        TokenVirtualBalances storage virtualBalanceTokenIn;
        TokenVirtualBalances storage virtualBalanceTokenOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (virtualBalanceTokenIn, virtualBalanceTokenOut) = (virtualBalances.tokenA, virtualBalances.tokenB);
        else (virtualBalanceTokenIn, virtualBalanceTokenOut) = (virtualBalances.tokenB, virtualBalances.tokenA);

        ctx.swap.balanceIn += remainingVirtualBalance(virtualBalanceTokenIn.asTokenOut, period);
        ctx.swap.balanceOut -= remainingVirtualBalance(virtualBalanceTokenOut.asTokenIn, period);

        uint216 virtualBalanceIn = remainingVirtualBalance(virtualBalanceTokenIn.asTokenIn, period);
        uint216 virtualBalanceOut = remainingVirtualBalance(virtualBalanceTokenOut.asTokenOut, period);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        virtualBalanceIn += amountIn.toUint216();
        virtualBalanceOut += amountOut.toUint216();

        if (!ctx.vm.isStaticContext) {
            virtualBalanceTokenIn.asTokenIn = VirtualBalanceLib.encode(virtualBalanceIn, uint40(block.timestamp));
            virtualBalanceTokenOut.asTokenOut = VirtualBalanceLib.encode(virtualBalanceOut, uint40(block.timestamp));
        }
    }

    /// @dev Virtual balance decreases linearly over time. Returns the remaining amount within the period.
    function remainingVirtualBalance(VirtualBalance data, uint16 period) internal view returns (uint216) {
        unchecked {
            (uint216 amount, uint40 ts) = VirtualBalanceLib.decode(data);

            uint256 expiration = uint256(ts) + period;
            if (block.timestamp >= expiration) return 0;
            uint256 timeLeft = expiration - block.timestamp;

            // timeLeft < period
            return uint216(amount * timeLeft / period);
        }
    }
}

/// @dev Virtual balance means the remaining amount of token that was swapped in previous swaps and not yet expired.
type VirtualBalance is uint256;

library VirtualBalanceLib {
    function encode(uint216 amount, uint40 ts) internal pure returns (VirtualBalance) {
        return VirtualBalance.wrap((uint256(amount) << 40) | ts);
    }

    function decode(VirtualBalance data) internal pure returns (uint216 amount, uint40 ts) {
        return (uint216(VirtualBalance.unwrap(data) >> 40), uint40(VirtualBalance.unwrap(data)));
    }
}
