// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { IProtocolFeeProvider } from "./interfaces/IProtocolFeeProvider.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;

library FeeArgsBuilder {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);
    error FeeMissingFeeBPS();
    error ProtocolFeeMissingFeeBPS();
    error ProtocolFeeMissingTo();
    error ProtocolFeeProviderMissingAddress();

    function buildFlatFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function buildProtocolFee(uint32 feeBps, address to) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps, to);
    }

    function buildDynamicProtocolFee(address feeProvider) internal pure returns (bytes memory) {
        return abi.encodePacked(feeProvider);
    }

    function parseFlatFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, FeeMissingFeeBPS.selector)));
    }

    function parseProtocolFee(bytes calldata args) internal pure returns (uint32 feeBps, address to) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProtocolFeeMissingFeeBPS.selector)));
        to = address(uint160(bytes20(args.slice(4, 24, ProtocolFeeMissingTo.selector))));
    }

    function parseDynamicProtocolFee(bytes calldata args) internal pure returns (address feeProvider) {
        feeProvider = address(uint160(bytes20(args.slice(0, 20, ProtocolFeeProviderMissingAddress.selector))));
    }
}

contract Fee {
    using ContextLib for Context;

    error FeeShouldBeAppliedBeforeSwapAmountsComputation();
    error FeeDynamicProtocolInvalidRecipient();
    error FeeBpsOutOfRange(uint256 feeBps);
    error FeeProtocolProviderFailedCall();

    /// @notice Emitted when a protocol fee transfer fails and the fee is skipped.
    /// @dev Fee charging is best-effort: a failed transfer never blocks the swap.
    ///   Indexed fields allow off-chain monitors to filter skipped fees by order,
    ///   token or recipient — monitoring this event is the compensating control
    ///   for the best-effort charging model.
    /// @param orderHash Unique identifier for the order/strategy
    /// @param token Token in which the fee was to be charged (tokenIn)
    /// @param feeAmount Fee amount that failed to transfer
    /// @param to Intended fee recipient
    event FeeChargeFailed(bytes32 indexed orderHash, address indexed token, uint256 feeAmount, address indexed to);

    IAqua internal immutable _AQUA;

    constructor(address aqua) {
        _AQUA = IAqua(aqua);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        // This is the same _feeAmountIn call, just with rounding up.
        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            ctx.swap.amountIn -= Math.ceilDiv(ctx.swap.amountIn * feeBps, BPS);
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            ctx.swap.amountIn += Math.ceilDiv(ctx.swap.amountIn * feeBps, BPS - feeBps);
        }
    }

    /// @notice Protocol fee on amountIn — transfers fee from maker to recipient via transferFrom.
    /// @dev BEST-EFFORT CHARGING: The fee transfer occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the transfer fails
    ///   (e.g. the maker lacks tokenIn balance or allowance at that point), the fee is skipped,
    ///   FeeChargeFailed is emitted and the swap proceeds — fees never block a swap. The skipped
    ///   fee simply remains uncollected. Monitor FeeChargeFailed off-chain.
    /// @dev Amounts are computed identically in quote and swap modes; in quote mode
    ///   (isStaticContext=true) the actual token transfer is skipped. Makers MUST NOT use backward
    ///   jumps to this instruction as it may break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext && feeAmountIn > 0 && !_tryPullFee(ctx.query.tokenIn, ctx.query.maker, to, feeAmountIn)) {
            emit FeeChargeFailed(ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
        }
    }

    /// @notice Protocol fee on amountIn for Aqua — pulls fee from maker's Aqua balance to recipient.
    /// @dev BEST-EFFORT CHARGING: The fee pull occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the pull fails
    ///   (e.g. the strategy's tokenIn balance is drained to a range boundary), the fee is skipped,
    ///   FeeChargeFailed is emitted and the swap proceeds — fees never block a swap. The skipped fee
    ///   remains in the maker's strategy balance, so a strategy at a range boundary effectively
    ///   trades fee-free in that direction until rebalanced. Monitor FeeChargeFailed off-chain.
    /// @dev amountNetPulled is increased only when the pull succeeds, keeping the post-push maker
    ///   balance check in SwapVM strict when the fee was not actually pulled.
    /// @dev Amounts are computed identically in quote and swap modes; in quote mode
    ///   (isStaticContext=true) the Aqua pull is skipped. Makers MUST NOT use backward jumps to
    ///   this instruction as it may break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            if (feeAmountIn > 0) {
                try _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to) {
                    ctx.swap.amountNetPulled += feeAmountIn;
                } catch {
                    emit FeeChargeFailed(ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
                }
            }
        } else {
            ctx.swap.amountNetPulled += feeAmountIn;
        }
    }

    /// @notice Dynamic protocol fee with external fee provider
    /// @dev BEST-EFFORT CHARGING: The fee transfer occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the transfer fails
    ///   (e.g. the maker lacks tokenIn balance or allowance at that point), the fee is skipped,
    ///   FeeChargeFailed is emitted and the swap proceeds — fees never block a swap. The skipped
    ///   fee simply remains uncollected. Monitor FeeChargeFailed off-chain.
    /// @dev Amounts are computed identically in quote and swap modes; in quote mode
    ///   (isStaticContext=true) the actual token transfer is skipped. Makers MUST NOT use backward
    ///   jumps to this instruction as it may break numerical consistency between quote() and swap().
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLock on orderHash level in SwapVM.swap()
    ///   - Fee calculation and state changes happen AFTER external call
    ///   - feeProvider MUST NOT rely on intermediate swap state
    ///   CAUTION: Takers should verify feeProvider trustworthiness before executing.
    ///      A malicious feeProvider could return large data causing high gas consumption.
    /// @param args.feeProvider | 20 bytes (address of the protocol fee provider)
    function _dynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        address feeProvider = FeeArgsBuilder.parseDynamicProtocolFee(args);
        uint256 feeBps;
        address to;

        if (feeProvider != address(0)) {
            (bool success, bytes memory result) = feeProvider.staticcall(abi.encodeCall(
                IProtocolFeeProvider.getFeeBpsAndRecipient,
                (ctx.query.orderHash,
                ctx.query.maker,
                ctx.query.taker,
                ctx.query.tokenIn,
                ctx.query.tokenOut,
                ctx.query.isExactIn)
            ));

            require(success && result.length == 64, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext && feeAmountIn > 0 && !_tryPullFee(ctx.query.tokenIn, ctx.query.maker, to, feeAmountIn)) {
                emit FeeChargeFailed(ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
            }
        }
    }

    /// @notice Dynamic protocol fee with external fee provider (Aqua version)
    /// @dev BEST-EFFORT CHARGING: The fee pull occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the pull fails
    ///   (e.g. the strategy's tokenIn balance is drained to a range boundary), the fee is skipped,
    ///   FeeChargeFailed is emitted and the swap proceeds — fees never block a swap. The skipped fee
    ///   remains in the maker's strategy balance. amountNetPulled is increased only when the pull
    ///   succeeds, keeping the post-push maker balance check in SwapVM strict.
    /// @dev Amounts are computed identically in quote and swap modes; in quote mode
    ///   (isStaticContext=true) the Aqua pull is skipped. Makers MUST NOT use backward jumps to
    ///   this instruction as it may break numerical consistency between quote() and swap().
    /// @dev REENTRANCY SAFETY:
    ///   - Uses staticcall preventing state changes by feeProvider
    ///   - Protected by TransientLock on orderHash level in SwapVM.swap()
    ///   - Fee calculation and state changes happen AFTER external call
    ///   - feeProvider MUST NOT rely on intermediate swap state
    ///   CAUTION: Takers should verify feeProvider trustworthiness before executing.
    ///      A malicious feeProvider could return large data causing high gas consumption.
    /// @param args.feeProvider | 20 bytes (address of the protocol fee provider)
    function _aquaDynamicProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        address feeProvider = FeeArgsBuilder.parseDynamicProtocolFee(args);
        uint256 feeBps;
        address to;

        if (feeProvider != address(0)) {
            (bool success, bytes memory result) = feeProvider.staticcall(abi.encodeCall(
                IProtocolFeeProvider.getFeeBpsAndRecipient,
                (ctx.query.orderHash,
                ctx.query.maker,
                ctx.query.taker,
                ctx.query.tokenIn,
                ctx.query.tokenOut,
                ctx.query.isExactIn)
            ));

            require(success && result.length == 64, FeeProtocolProviderFailedCall());
            (feeBps, to) = abi.decode(result, (uint32, address));
            require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        }

        if (feeBps != 0) {
            require(to != address(0), FeeDynamicProtocolInvalidRecipient());

            uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

            if (!ctx.vm.isStaticContext) {
                if (feeAmountIn > 0) {
                    try _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to) {
                        ctx.swap.amountNetPulled += feeAmountIn;
                    } catch {
                        emit FeeChargeFailed(ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to);
                    }
                }
            } else {
                ctx.swap.amountNetPulled += feeAmountIn;
            }
        }
    }

    // Internal functions

    /// @notice Attempts to transfer a protocol fee from the maker without reverting on failure.
    /// @dev Non-reverting ERC20 transferFrom used for best-effort fee charging: callers skip
    ///   the fee (and emit FeeChargeFailed) when this returns false, so a failed fee transfer
    ///   never blocks the swap.
    ///   Mirrors the success semantics of solidity-utils SafeERC20.safeTransferFrom:
    ///   - the low-level call itself must succeed, AND
    ///   - either no return data is present and the token is a deployed contract
    ///     (covers non-standard tokens like USDT that return nothing), OR
    ///   - at least 32 bytes are returned and decode to boolean `true`.
    ///   Assembly is used to avoid copying unbounded return data to memory (returndata bomb
    ///   protection) and to keep gas parity with SafeERC20 on the success path.
    ///   Note: `maker` and `to` originate from calldata parsing (query struct / bytes20 slice),
    ///   so their higher bits are already clean and no masking is performed.
    /// @param token ERC20 token to charge the fee in (tokenIn of the current swap)
    /// @param maker Address the fee is pulled from
    /// @param to Fee recipient
    /// @param amount Fee amount to transfer
    /// @return success True if the transfer succeeded, false if it failed for any reason
    function _tryPullFee(address token, address maker, address to, uint256 amount) private returns (bool success) {
        bytes4 selector = IERC20.transferFrom.selector;
        assembly ("memory-safe") { // solhint-disable-line no-inline-assembly
            let data := mload(0x40)

            mstore(data, selector)
            mstore(add(data, 0x04), maker)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            success := call(gas(), token, 0, data, 0x64, 0x0, 0x20)
            if success {
                switch returndatasize()
                case 0 {
                    success := gt(extcodesize(token), 0)
                }
                default {
                    success := and(gt(returndatasize(), 31), eq(mload(0), 1))
                }
            }
        }
    }

    function _feeAmountIn(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
            ctx.swap.amountIn -= feeAmountIn;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
        }
    }
}
