// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice BaseFeeAdjuster opcode, price adjustment based on network gas costs
/// @dev Encoding: [bool adjustIn, uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount]
/// @dev Supports only single direction swaps; ETH price specified in token in for `adjustIn = true` or token out for `adjustIn = false`
/// @dev Adjustment is applied to the total or remaining balance depending on ordering with InvalidateTokenOut for `adjustIn = true` or
///   InvalidateTokenIn for `adjustIn = false`
library BaseFeeAdjuster {
    using CalldataParse for bytes;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.BaseFeeAdjuster;

    uint256 constant ONE = 1e18;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 1 + 8 + 12 + 3;
    }

    function build(bool adjustIn, uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), adjustIn, baseGasPrice, ethPrice, gasAmount).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        bool adjustIn,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(InstructionBuilder.encodeBool(adjustIn, 0)).push(baseGasPrice, 8).push(ethPrice, 12).push(gasAmount, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (bool adjustIn, uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) {
        adjustIn = args.at(0).asBool(0);
        baseGasPrice = args.at(1).asU64();
        ethPrice = args.at(9).asU96();
        gasAmount = args.at(21).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (bool adjustIn, uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) = parse(args);

        if (block.basefee <= baseGasPrice) return;

        uint256 adjustment = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        if (adjustment > ctx.swap.surcharge) adjustment = ctx.swap.surcharge;

        unchecked { ctx.swap.surcharge -= adjustment; }
        if (adjustIn) ctx.swap.balanceIn -= adjustment;
        else ctx.swap.balanceOut += adjustment;
    }
}
