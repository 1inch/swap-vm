// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library BalancesArgsBuilder {
    using SafeCast for uint256;
    using Calldata for bytes;

    function build(uint256[2] memory balances) internal pure returns (bytes memory) {
        return abi.encodePacked(balances[0], balances[1]);
    }

    function parse(bytes calldata args) internal pure returns (uint256 balanceA, uint256 balanceB) {
        balanceA = uint256(bytes32(args));
        balanceB = uint256(bytes32(args.slice(32)));
    }
}

contract Balances {
    using Calldata for bytes;
    using ContextLib for Context;

    error SetBalancesExpectZeroBalances(uint256 balanceIn, uint256 balanceOut);

    mapping(bytes32 orderHash =>
        mapping(address token => uint256)) public balances;

    /// @dev Sets ctx.swap.balanceIn/Out from provided initial balances
    /// @param args.initialBalances[2] | 32 bytes * 2
    function _staticBalancesXD(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(ctx.swap.balanceIn, ctx.swap.balanceOut));

        uint256 balanceIn;
        uint256 balanceOut;
        if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = BalancesArgsBuilder.parse(args);
        else (balanceOut, balanceIn) = BalancesArgsBuilder.parse(args);

        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
    }

    /// @dev Load or init ctx.swap.balanceIn/Out from provided initial balances,
    ///      then execute sub-instruction and apply swap amounts to stored balances
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction reads balances
    ///   but does NOT update them after nested instructions complete. Quote may succeed while swap reverts
    ///   if balances were modified between quote and swap calls. Makers MUST NOT use backward jumps to
    ///   this instruction as it breaks numerical consistency between quote() and swap().
    /// @param args.initialBalances[2] | 32 bytes * 2
    function _dynamicBalancesXD(Context memory ctx, bytes calldata args) internal {
        require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(ctx.swap.balanceIn, ctx.swap.balanceOut));

        uint256 balanceIn = balances[ctx.query.orderHash][ctx.query.tokenIn];
        uint256 balanceOut = balances[ctx.query.orderHash][ctx.query.tokenOut];

        if (balanceIn | balanceOut == 0) {
            if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = BalancesArgsBuilder.parse(args);
            else (balanceOut, balanceIn) = BalancesArgsBuilder.parse(args);

            if (!ctx.vm.isStaticContext) {
                balances[ctx.query.orderHash][ctx.query.tokenIn] = balanceIn;
                balances[ctx.query.orderHash][ctx.query.tokenOut] = balanceOut;
            }
        }

        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;

        ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            balances[ctx.query.orderHash][ctx.query.tokenIn] += ctx.swap.amountIn;
            balances[ctx.query.orderHash][ctx.query.tokenOut] -= ctx.swap.amountOut;
        }
    }
}
