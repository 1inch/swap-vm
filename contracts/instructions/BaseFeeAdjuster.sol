// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice BaseFeeAdjusterBalanceIn opcode, price adjustment based on network gas costs
/// @dev Encoding: [uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount]
/// @dev Supports only single direction swaps, eth price specified in token in
/// @dev Adjustment is applied to the total or remaining balance depending on ordering with InvalidateTokenOut opcode
library BaseFeeAdjusterBalanceIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.BaseFeeAdjusterBalanceIn;

    uint256 constant ONE = 1e18;

    function sizeOf(uint64, uint96, uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 8 + 12 + 3;
    }

    function build(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(baseGasPrice, ethPrice, gasAmount)), baseGasPrice, ethPrice, gasAmount).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(baseGasPrice, 8).push(ethPrice, 12).push(gasAmount, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) {
        baseGasPrice = args.at(0).asU64();
        ethPrice = args.at(8).asU96();
        gasAmount = args.at(20).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) = parse(args);

        if (block.basefee <= baseGasPrice) return;

        uint256 tokenInDiscount = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        if (tokenInDiscount > ctx.swap.surcharge) tokenInDiscount = ctx.swap.surcharge;

        ctx.swap.surcharge -= tokenInDiscount;
        ctx.swap.balanceIn -= tokenInDiscount;
    }
}

/// @notice BaseFeeAdjusterBalanceOut opcode, price adjustment based on network gas costs
/// @dev Encoding: [uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount]
/// @dev Supports only single direction swaps, eth price specified in token out
/// @dev Adjustment is applied to the total or remaining balance depending on ordering with InvalidateTokenIn opcode
library BaseFeeAdjusterBalanceOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    Opcode constant opcode = Opcode.BaseFeeAdjusterBalanceOut;

    uint256 constant ONE = 1e18;

    function sizeOf(uint64, uint96, uint24) internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 8 + 12 + 3;
    }

    function build(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf(baseGasPrice, ethPrice, gasAmount)), baseGasPrice, ethPrice, gasAmount).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint64 baseGasPrice,
        uint96 ethPrice,
        uint24 gasAmount
    ) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(baseGasPrice, 8).push(ethPrice, 12).push(gasAmount, 3);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) {
        baseGasPrice = args.at(0).asU64();
        ethPrice = args.at(8).asU96();
        gasAmount = args.at(20).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount) = parse(args);

        if (block.basefee <= baseGasPrice) return;

        uint256 tokenOutPremium = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        if (tokenOutPremium > ctx.swap.surcharge) tokenOutPremium = ctx.swap.surcharge;

        ctx.swap.surcharge -= tokenOutPremium;
        ctx.swap.balanceOut += tokenOutPremium;
    }
}
