// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice XYCSwap opcode, constant-product swap curve
/// @dev Encoding: []
library XYCSwap {
    using MemoryPtrLib for MemoryPtr;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    Opcode constant opcode = Opcode.XYCSwap;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf();
    }

    function build() internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf())).resolve();
    }

    function build(MemoryPtr ptrStart) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptrStart.patchLength(ptr);
    }

    function exec(Context memory ctx, bytes calldata) internal pure {
        if (ctx.query.isExactIn) {
            // Floor division for tokenOut favors maker
            ctx.swap.amountOut = ctx.swap.amountIn * ctx.swap.balanceOut / (ctx.swap.balanceIn + ctx.swap.amountIn);
        } else {
            // Ceil division for tokenIn favors maker
            ctx.swap.amountIn = (ctx.swap.amountOut * ctx.swap.balanceIn).ceilDiv(ctx.swap.balanceOut - ctx.swap.amountOut);
        }
    }
}
