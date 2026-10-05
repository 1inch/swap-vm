// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionHeader } from "../libs/InstructionHeader.sol";

/// @notice RequireMinRate opcode, maker-favor rate guard, fails if rate is worse than specified
///   Validates final amounts after rest of strategy executed
/// @dev Encoding: [uint64 rateA, uint64 rateB]
/// @dev Supports only single direction swaps
library RequireMinRate {
    using CalldataParse for bytes;
    using InstructionHeader for MemoryPtr;

    error RequireMinRateFailed(uint256 amountIn, uint256 amountOut, uint256 rateIn, uint256 rateOut);

    Opcode constant opcode = Opcode.RequireMinRate;

    function sizeOf() internal pure returns (uint256) {
        return InstructionHeader.sizeOf() + 8 + 8;
    }

    function build(uint64 rateA, uint64 rateB) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), rateA, rateB).resolve();
    }

    function build(MemoryPtr ptrStart, uint64 rateA, uint64 rateB) internal pure returns (MemoryPtr ptr) {
        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(rateA, 8).push(rateB, 8);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint64 rateA, uint64 rateB) {
        rateA = args.at(0).asU64();
        rateB = args.at(8).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal {
        InstructionHeader.exactLength(sizeOf(), args);

        uint64 rateIn; uint64 rateOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (rateIn, rateOut) = parse(args);
        else (rateOut, rateIn) = parse(args);

        (uint256 amountIn, uint256 amountOut) = ctx.runLoop();

        // Cross-multiplication for: amountIn / amountOut >= rateIn / rateOut
        require(amountIn * rateOut >= rateIn * amountOut, RequireMinRateFailed(amountIn, amountOut, rateIn, rateOut));
    }
}
