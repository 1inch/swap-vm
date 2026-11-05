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
/// @dev Fees are reinvested; curvature decreases because the linear term grows faster as balances increase
/// @dev Encoding: [uint144 anchorA, uint144 anchorB, uint104 width]; width encoded with ONE as precision
library PeggedSwap {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    error PeggedSwapInvalidWidth(uint104 width);
    error PeggedSwapInvalidAnchors(uint144 anchorA, uint144 anchorB);
    error PeggedSwapContextOverflow();

    Opcode constant opcode = Opcode.PeggedSwap;

    uint256 internal constant ONE = 1e27;
    uint256 internal constant ONEx2 = 1e54;

    function sizeOf() internal pure returns (uint256) {
        return InstructionBuilder.sizeOf() + 18 + 18 + 13;
    }

    function build(uint144 anchorA, uint144 anchorB, uint104 width) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), anchorA, anchorB, width).resolve();
    }

    function build(MemoryPtr ptrStart, uint144 anchorA, uint144 anchorB, uint104 width) internal pure returns (MemoryPtr ptr) {
        require(anchorA > 0 && anchorB > 0, PeggedSwapInvalidAnchors(anchorA, anchorB));
        require(width >= ONE / 4 && width <= 5_000 * ONE, PeggedSwapInvalidWidth(width));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr.push(anchorA, 18).push(anchorB, 18).push(width, 13);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args) internal pure returns (uint144 anchorA, uint144 anchorB, uint104 width) {
        anchorA = args.at(0).asU144();
        anchorB = args.at(18).asU144();
        width = args.at(36).asU104();
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        uint144 anchorIn; uint144 anchorOut; uint104 width;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (anchorIn, anchorOut, width) = parse(args);
        else (anchorOut, anchorIn, width) = parse(args);

        unchecked {
            require(
                (ctx.swap.amountIn >> 144) + (ctx.swap.amountOut >> 144) +
                (ctx.swap.balanceIn >> 144) + (ctx.swap.balanceOut >> 144) == 0,
                PeggedSwapContextOverflow()
            );
        }

        // Maker favored rounding:
        // `least = liquidity - contribution` round up + solve(least) round up ->
        // `amountIn = solve(least) - balanceIn` round up or `amountOut = balanceOut - solve(least)` round down

        uint256 liquidity; // Current curve value, has token in and token out contribution parts
        unchecked {
            liquidity =
                ONEx2.mulDiv(ctx.swap.balanceIn, anchorIn, Math.Rounding.Ceil).sqrt(Math.Rounding.Ceil) +
                (width * ctx.swap.balanceIn).ceilDiv(anchorIn) +
                ONEx2.mulDiv(ctx.swap.balanceOut, anchorOut, Math.Rounding.Ceil).sqrt(Math.Rounding.Ceil) +
                (width * ctx.swap.balanceOut).ceilDiv(anchorOut);
        }

        if (ctx.query.isExactIn) {
            uint256 contribution; // Contribution to curve value made by token in considering both balance and swap amount
            unchecked {
                uint256 postBalanceIn = ctx.swap.balanceIn + ctx.swap.amountIn;
                contribution = ONEx2.mulDiv(postBalanceIn, anchorIn).sqrt() + width * postBalanceIn / anchorIn;
            }

            if (contribution >= liquidity) { // Single side contribution exceeds liquidity -> partial fill
                ctx.swap.amountIn = solve(liquidity, width, anchorIn) - ctx.swap.balanceIn;
                ctx.swap.amountOut = ctx.swap.balanceOut;
            } else {
                unchecked { ctx.swap.amountOut = ctx.swap.balanceOut - solve(liquidity - contribution, width, anchorOut); }
                if (ctx.swap.amountOut > ctx.swap.balanceOut) ctx.swap.amountOut = 0; // underflow trick
            }
        } else {
            if (ctx.swap.amountOut > ctx.swap.balanceOut) ctx.swap.amountOut = ctx.swap.balanceOut; // Partial fill support

            uint256 contribution; // Contribution to curve value made by token out considering both balance and swap amount
            unchecked {
                uint256 postBalanceOut = ctx.swap.balanceOut - ctx.swap.amountOut;
                contribution = ONEx2.mulDiv(postBalanceOut, anchorOut).sqrt() + width * postBalanceOut / anchorOut;
            }

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
    function solve(uint256 contribution, uint256 width, uint256 anchor) internal pure returns (uint256 balance) {
        unchecked {
            require(contribution >> 128 == 0, PeggedSwapContextOverflow());
            uint256 disc = ONEx2 + 4 * width * contribution; // uint180 + uint8 * uint104 * uint128 <= uint240
            uint256 denom = ONEx2 + disc + ONE * (4 * disc).sqrt(); // uint180 + uint240 + uint90 * (uint8 * uint240).sqrt() <= uint240
            balance = (4 * anchor).mulDiv(contribution * contribution, denom, Math.Rounding.Ceil);
        }
    }
}
