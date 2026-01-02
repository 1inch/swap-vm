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

    error BalancesArgsBuilderArraysLengthMismatch(uint256 tokensLength, uint256 balancesLength);
    error BalancesParsingMissingTokensCount();
    error BalancesParsingMissingTokens();
    error BalancesParsingMissingInitialBalances();

    function build(address[] memory tokens, uint256[] memory balances) internal pure returns (bytes memory) {
        require(tokens.length == balances.length, BalancesArgsBuilderArraysLengthMismatch(tokens.length, balances.length));
        bytes memory packed = abi.encodePacked((tokens.length).toUint16());
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, tokens[i]);
        }
        return abi.encodePacked(packed, balances);
    }

    function parse(bytes calldata args) internal pure returns (uint256 tokensCount, bytes calldata tokens, bytes calldata initialBalances) {
        unchecked {
            tokensCount = uint16(bytes2(args.slice(0, 2, BalancesParsingMissingTokensCount.selector)));
            uint256 balancesOffset = 2 + 20 * tokensCount;
            uint256 subargsOffset = balancesOffset + 32 * tokensCount;

            tokens = args.slice(2, balancesOffset, BalancesParsingMissingTokens.selector);
            initialBalances = args.slice(balancesOffset, subargsOffset, BalancesParsingMissingInitialBalances.selector);
        }
    }
}

contract Balances {
    using Calldata for bytes;
    using ContextLib for Context;

    error SetBalancesExpectZeroBalances(uint256 balanceIn, uint256 balanceOut);
    error StaticBalancesRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);
    error DynamicBalancesLoadingRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);
    error DynamicBalancesInitRequiresSettingBothBalances(address tokenIn, address tokenOut, bytes tokens);

    mapping(bytes32 orderHash =>
        mapping(address token => uint256)) public balances;

    /// @dev Sets ctx.swap.balanceIn/Out from provided initial balances
    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]  | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _staticBalancesXD(Context memory ctx, bytes calldata args) internal pure {
        require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(ctx.swap.balanceIn, ctx.swap.balanceOut));

        (uint256 tokensCount, bytes calldata tokens, bytes calldata initialBalances) = BalancesArgsBuilder.parse(args);
        bool foundTokenIn = false;
        bool foundTokenOut = false;
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 initialBalance = uint256(bytes32(initialBalances.slice(i * 32)));
            if (token == ctx.query.tokenIn) {
                ctx.swap.balanceIn = initialBalance;
                foundTokenIn = true;
            } else if (token == ctx.query.tokenOut) {
                ctx.swap.balanceOut = initialBalance;
                foundTokenOut = true;
            }
        }

        require(foundTokenIn && foundTokenOut, StaticBalancesRequiresSettingBothBalances(ctx.query.tokenIn, ctx.query.tokenOut, tokens));
    }

    /// @dev Load or init ctx.swap.balanceIn/Out from provided initial balances,
    ///      then execute sub-instruction and apply swap amounts to stored balances
    /// @param args.tokensCount       | 2 bytes
    /// @param args.tokens[]  | 20 bytes * args.tokensCount
    /// @param args.initialBalances[] | 32 bytes * args.tokensCount
    function _dynamicBalancesXD(Context memory ctx, bytes calldata args) internal {
        (uint256 tokensCount, bytes calldata tokens, bytes calldata initialBalances) = BalancesArgsBuilder.parse(args);
        if (!_loadBalances(ctx, tokensCount, tokens)) {
            _initBalances(ctx, tokensCount, tokens, initialBalances);
        }

        (uint256 swapAmountIn, uint256 swapAmountOut) = ctx.runLoop();

        if (!ctx.vm.isStaticContext) {
            balances[ctx.query.orderHash][ctx.query.tokenIn] += swapAmountIn;
            balances[ctx.query.orderHash][ctx.query.tokenOut] -= swapAmountOut;
        }
    }

    function _loadBalances(Context memory ctx, uint256 tokensCount, bytes calldata tokens) private view returns (bool hasNonZeroBalances) {
        hasNonZeroBalances = false;
        bool foundTokenIn = false;
        bool foundTokenOut = false;
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 balance = balances[ctx.query.orderHash][token];
            hasNonZeroBalances = hasNonZeroBalances || (balance != 0);

            if (token == ctx.query.tokenIn) {
                ctx.swap.balanceIn = balance;
                foundTokenIn = true;
            } else if (token == ctx.query.tokenOut) {
                ctx.swap.balanceOut = balance;
                foundTokenOut = true;
            }

            if (foundTokenIn && foundTokenOut && hasNonZeroBalances) {
                // Early exit when both balances loaded and at least one non-zero balance found means state is not uninitialized
                return hasNonZeroBalances;
            }
        }
        require(foundTokenIn && foundTokenOut, DynamicBalancesLoadingRequiresSettingBothBalances(ctx.query.tokenIn, ctx.query.tokenOut, tokens));
    }

    function _initBalances(Context memory ctx, uint256 tokensCount, bytes calldata tokens, bytes calldata initialBalances) private {
        bool foundTokenIn = false;
        bool foundTokenOut = false;
        for (uint256 i = 0; i < tokensCount; i++) {
            address token = address(bytes20(tokens.slice(i * 20)));
            uint256 initialBalance = uint256(bytes32(initialBalances.slice(i * 32)));
            if (!ctx.vm.isStaticContext) {
                balances[ctx.query.orderHash][token] = initialBalance;
            }

            if (token == ctx.query.tokenIn) {
                ctx.swap.balanceIn = initialBalance;
                foundTokenIn = true;
            } else if (token == ctx.query.tokenOut) {
                ctx.swap.balanceOut = initialBalance;
                foundTokenOut = true;
            }
        }

        require(foundTokenIn && foundTokenOut, DynamicBalancesInitRequiresSettingBothBalances(ctx.query.tokenIn, ctx.query.tokenOut, tokens));
    }
}
