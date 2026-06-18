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

    error BalancesNon2Tokens(uint256 actualLength);
    error BalancesParsingMissingTokensCount();
    error BalancesParsingMissingTokens();
    error BalancesParsingMissingInitialBalances();

    function build(address[] memory tokens, uint256[] memory balances) internal pure returns (bytes memory) {
        require(balances.length == 2, BalancesNon2Tokens(balances.length));
        require(tokens.length == 2, BalancesNon2Tokens(tokens.length));

        return abi.encodePacked(balances[0], balances[1], tokens[0] < tokens[1]);
    }

    function parse(bytes calldata args) internal pure returns (uint256 balanceA, uint256 balanceB, bool direction) {
        assembly ("memory-safe") {
            balanceA := calldataload(args.offset)
            balanceB := calldataload(add(args.offset, 32))
            direction := shr(248, calldataload(add(args.offset, 64)))
        }
    }
}

abstract contract Balances {
    using Calldata for bytes;
    using ContextLib for Context;

    error SetBalancesExpectZeroBalances(uint256 balanceIn, uint256 balanceOut);
    error StaticBalancesRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);
    error DynamicBalancesLoadingRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);
    error DynamicBalancesInitRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);

    mapping(bytes32 orderHash =>
        mapping(address token => uint256)) public balances;

    function _runLoop(Context memory ctx) internal virtual;

    /// @dev Sets ctx.swap.balanceIn/Out from provided initial balances
    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]          | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _staticBalancesXD(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(ctx.swap.balanceIn, ctx.swap.balanceOut));

        (uint256 balanceA, uint256 balanceB, bool makerDirectionLt) = BalancesArgsBuilder.parse(args);
        bool takerDirectionLt = ctx.query.tokenIn < ctx.query.tokenOut;

        if (makerDirectionLt == takerDirectionLt) {
            ctx.swap.balanceIn = balanceA;
            ctx.swap.balanceOut = balanceB;
        } else {
            ctx.swap.balanceIn = balanceB;
            ctx.swap.balanceOut = balanceA;
        }
    }

    /// @dev Load or init ctx.swap.balanceIn/Out from provided initial balances,
    ///      then execute sub-instruction and apply swap amounts to stored balances
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction reads balances
    ///   but does NOT update them after nested instructions complete. Quote may succeed while swap reverts
    ///   if balances were modified between quote and swap calls. Makers MUST NOT use backward jumps to
    ///   this instruction as it breaks numerical consistency between quote() and swap().
    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]          | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _dynamicBalancesXD(Context memory ctx, bytes calldata args) internal {
        if (!ctx.vm.isStaticContext) {
            if (balances[ctx.query.orderHash][ctx.query.tokenIn] | balances[ctx.query.orderHash][ctx.query.tokenOut] == 0) {
                (uint256 balanceA, uint256 balanceB, bool makerDirectionLt) = BalancesArgsBuilder.parse(args);
                bool takerDirectionLt = ctx.query.tokenIn < ctx.query.tokenOut;

                if (makerDirectionLt == takerDirectionLt) {
                    balances[ctx.query.orderHash][ctx.query.tokenIn] = balanceA;
                    balances[ctx.query.orderHash][ctx.query.tokenOut] = balanceB;
                } else {
                    balances[ctx.query.orderHash][ctx.query.tokenIn] = balanceB;
                    balances[ctx.query.orderHash][ctx.query.tokenOut] = balanceA;
                }
            }

            ctx.swap.balanceIn = balances[ctx.query.orderHash][ctx.query.tokenIn];
            ctx.swap.balanceOut = balances[ctx.query.orderHash][ctx.query.tokenOut];

            _runLoop(ctx);

            balances[ctx.query.orderHash][ctx.query.tokenIn] += ctx.swap.amountIn;
            balances[ctx.query.orderHash][ctx.query.tokenOut] -= ctx.swap.amountOut;
        } else {
            ctx.swap.balanceIn = balances[ctx.query.orderHash][ctx.query.tokenIn];
            ctx.swap.balanceOut = balances[ctx.query.orderHash][ctx.query.tokenOut];
            
            if (ctx.swap.balanceIn | ctx.swap.balanceOut == 0) {
                (uint256 balanceA, uint256 balanceB, bool makerDirectionLt) = BalancesArgsBuilder.parse(args);
                bool takerDirectionLt = ctx.query.tokenIn < ctx.query.tokenOut;

                if (makerDirectionLt == takerDirectionLt) {
                    ctx.swap.balanceIn = balanceA;
                    ctx.swap.balanceOut = balanceB;
                } else {
                    ctx.swap.balanceIn = balanceB;
                    ctx.swap.balanceOut = balanceA;
                }
            }

            _runLoop(ctx);
        }
    }
}
