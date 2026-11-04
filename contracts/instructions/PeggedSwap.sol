// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice PeggedSwap opcode, swap curve for pegged assets
/// @dev Curve liquidity invariant is defined as follows
///   `sqrt(balanceIn / anchorIn) + sqrt(balanceOut / anchorOut) + width * (balanceIn / anchorIn + balanceOut / anchorOut)`
///   Initially suppose balances are at the anchors `liquidity = 2 + 2 * width`
///   The curve has finite reserves
/// @dev Fees are reinvested, curvature decreses due to linear term grows faster with increasing balances
/// @dev Encoding: [uint256 anchorA, uint256 anchorB, uint128 width]
///   width encoded with ONE as precision
library PeggedSwap {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    error PeggedSwapInvalidWidth(uint128 width);
    error PeggedSwapInvalidAnchors(uint256 anchorA, uint256 anchorB);

    Opcode constant opcode = Opcode.PeggedSwap;

    uint256 internal constant ONE = 1e27;
    uint256 internal constant ONEx2 = 1e54;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 32 + 32 + 16;
    }

    function build(uint256 anchorA, uint256 anchorB, uint128 width) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), anchorA, anchorB, width).resolve();
    }

    function build(MemoryPtr ptrStart, uint256 anchorA, uint256 anchorB, uint128 width) internal pure returns (MemoryPtr ptr) {
        require(anchorA > 0 && anchorB > 0, PeggedSwapInvalidAnchors(anchorA, anchorB));
        require(width <= 5_000 * ONE, PeggedSwapInvalidWidth(width));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(anchorA, 32).push(anchorB, 32).push(width, 16);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint256 anchorA, uint256 anchorB, uint128 width) {
        anchorA = args.at(0).asU256();
        anchorB = args.at(32).asU256();
        width = args.at(64).asU128();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint256 anchorIn; uint256 anchorOut; uint128 width;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (anchorIn, anchorOut, width) = parse(args);
        else (anchorOut, anchorIn, width) = parse(args);
        
        // Maker favored rounding:
        // `least = liquidity - contribution` round up + solve(least) round up ->
        // `amountIn = solve(least) - balanceIn` round up or `amountOut = balanceOut - solve(least)` round down

        // Current curve value, has token in and token out contribution parts
        uint256 liquidity =
            ONEx2.mulDiv(ctx.swap.balanceIn, anchorIn, Math.Rounding.Ceil).sqrt(Math.Rounding.Ceil) +
            (width * ctx.swap.balanceIn).ceilDiv(anchorIn) +
            ONEx2.mulDiv(ctx.swap.balanceOut, anchorOut, Math.Rounding.Ceil).sqrt(Math.Rounding.Ceil) +
            (width * ctx.swap.balanceOut).ceilDiv(anchorOut);

        if (ctx.query.isExactIn) {
            // Contribution to curve value made by token in considering both balance and swap amount
            uint256 contribution =
                ONEx2.mulDiv(ctx.swap.balanceIn + ctx.swap.amountIn, anchorIn).sqrt() +
                width * (ctx.swap.balanceIn + ctx.swap.amountIn) / anchorIn;

            if (contribution >= liquidity) { // Single side contribution exceeds liquidity -> partial fill
                ctx.swap.amountIn = solve(liquidity, width, anchorIn) - ctx.swap.balanceIn;
                ctx.swap.amountOut = ctx.swap.balanceOut;
            } else {
                unchecked { ctx.swap.amountOut = ctx.swap.balanceOut - solve(liquidity - contribution, width, anchorOut); }
                if (ctx.swap.amountOut > ctx.swap.balanceOut) ctx.swap.amountOut = 0; // underflow trick
            }
        } else {
            if (ctx.swap.amountOut > ctx.swap.balanceOut) ctx.swap.amountOut = ctx.swap.balanceOut; // Partial fill support

            // Contribution to curve value made by token out considering both balance and swap amount
            uint256 contribution =
                ONEx2.mulDiv(ctx.swap.balanceOut - ctx.swap.amountOut, anchorOut).sqrt() +
                width * (ctx.swap.balanceOut - ctx.swap.amountOut) / anchorOut;

            ctx.swap.amountIn = solve(liquidity - contribution, width, anchorIn) - ctx.swap.balanceIn;
        }
    }

    /// @notice Compute token balance from least side contribution
    /// @dev Computations rationale:
    ///   `contribution = sqrt(balance / anchor) + width * balance / anchor`
    ///   `contribution = sqrt(balance / anchor) + width * sqrt(balance / anchor) ** 2`
    ///   `sqrt(balance / anchor) = (-1 + sqrt(1 + 4 * width * contribution)) / (2 * width)`
    ///   `sqrt(balance / anchor) = 2 * contribution / (1 + sqrt(1 + 4 * width * contribution))`
    ///   `balance = 4 * anchor * contribution ** 2 / (1 + sqrt(1 + 4 * width * contribution)) ** 2`
    /// @dev Rounds up, expected to consume `contribution` rounded up, may exceed real balance behind the side
    function solve(uint256 contribution, uint128 width, uint256 anchor) internal pure returns (uint256 balance) {
        uint256 denom = ONE + (ONEx2 + 4 * width * contribution).sqrt();
        balance = (4 * anchor).mulDiv(contribution * contribution, denom * denom, Math.Rounding.Ceil);
    }
}
