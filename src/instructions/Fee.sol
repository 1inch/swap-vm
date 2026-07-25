// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
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
    using SafeERC20 for IERC20;
    using ContextLib for Context;

    error FeeShouldBeAppliedBeforeSwapAmountsComputation();
    error FeeDynamicProtocolInvalidRecipient();
    error FeeBpsOutOfRange(uint256 feeBps);
    error FeeProtocolProviderFailedCall();

    /// @notice Emitted when an Aqua protocol fee could not be collected and the swap proceeded without it
    /// @dev Off-chain monitoring MUST watch this event: it is the only signal that protocol revenue was
    ///   not collected, and an uncollected fee stays with the maker.
    /// @param orderHash Strategy the fee was charged against
    /// @param token The tokenIn the fee was denominated in
    /// @param to Recipient that was not paid
    /// @param amount Fee amount that was not collected
    event ProtocolFeeSkipped(bytes32 orderHash, address token, address to, uint256 amount);

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

    /// @notice Protocol fee on amountIn — transfers fee from maker to recipient via safeTransferFrom.
    /// @dev IMPORTANT: The maker MUST already hold sufficient tokenIn balance and have approved this contract
    ///   BEFORE the swap is executed. The fee transfer occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the maker lacks tokenIn
    ///   balance or allowance, the swap will revert.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the actual token transfer. Quote may succeed while swap reverts due to insufficient
    ///   balance or missing approval. Makers MUST NOT use backward jumps to this instruction as it may
    ///   break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            IERC20(ctx.query.tokenIn).safeTransferFrom(ctx.query.maker, to, feeAmountIn);
        }
    }

    /// @notice Protocol fee on amountIn for Aqua — pulls fee from maker's Aqua balance to recipient.
    /// @dev The fee pull occurs during program execution (inside runLoop), which is before SwapVM completes
    ///   the taker→maker tokenIn transfer, so it comes out of the maker's pre-existing Aqua tokenIn balance.
    ///   BEST-EFFORT COLLECTION: a maker who cannot cover the fee does not pay it and the swap proceeds,
    ///   reported through ProtocolFeeSkipped. See _tryPullFee for who ends up with an uncollected fee.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the Aqua pull operation, so quote() cannot tell a taker whether the fee will actually be
    ///   collected. Amounts are unaffected either way. Makers MUST NOT use backward jumps to this
    ///   instruction as it may break numerical consistency between quote() and swap().
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);

        // A fee that names no recipient can never be paid, so it is a configuration error rather than a
        // maker who is temporarily short, and it must not disappear into the skip path. Checked against the
        // program args rather than the computed amount so that it holds for dust trades and in quote mode
        // too, matching what the dynamic variants already do.
        if (feeBps != 0) require(to != address(0), FeeDynamicProtocolInvalidRecipient());

        uint256 feeAmountIn = _feeAmountIn(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _tryPullFee(ctx, to, feeAmountIn);
        }
    }

    /// @notice Dynamic protocol fee with external fee provider
    /// @dev IMPORTANT: The maker MUST already hold sufficient tokenIn balance and have approved this contract
    ///   BEFORE the swap is executed. The fee transfer occurs during program execution (inside runLoop),
    ///   which is before SwapVM completes the taker→maker tokenIn transfer. If the maker lacks tokenIn
    ///   balance or allowance, the swap will revert.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the actual token transfer. Quote may succeed while swap reverts due to insufficient
    ///   balance or missing approval. Makers MUST NOT use backward jumps to this instruction as it may
    ///   break numerical consistency between quote() and swap().
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

            if (!ctx.vm.isStaticContext && feeAmountIn > 0) {
                IERC20(ctx.query.tokenIn).safeTransferFrom(ctx.query.maker, to, feeAmountIn);
            }
        }
    }

    /// @notice Dynamic protocol fee with external fee provider (Aqua version)
    /// @dev The fee pull occurs during program execution (inside runLoop), which is before SwapVM completes
    ///   the taker→maker tokenIn transfer, so it comes out of the maker's pre-existing Aqua tokenIn balance.
    ///   BEST-EFFORT COLLECTION: a maker who cannot cover the fee does not pay it and the swap proceeds,
    ///   reported through ProtocolFeeSkipped. See _tryPullFee for who ends up with an uncollected fee.
    /// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction computes the fee
    ///   but skips the Aqua pull operation, so quote() cannot tell a taker whether the fee will actually be
    ///   collected. Amounts are unaffected either way. Makers MUST NOT use backward jumps to this
    ///   instruction as it may break numerical consistency between quote() and swap().
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

            if (!ctx.vm.isStaticContext && feeAmountIn > 0) {
                _tryPullFee(ctx, to, feeAmountIn);
            }
        }
    }

    // Internal functions

    /// @dev Pulls the protocol fee from the maker's Aqua balance, tolerating a maker who cannot cover it.
    ///   The pull runs before SwapVM credits the taker's tokenIn, so it is payable only out of inventory the
    ///   maker already holds. Reverting instead would make a one-sided position untradable and cap a
    ///   two-sided one at `balanceIn * BPS / feeBps` per swap (OpenZeppelin M-09, Theori #10).
    ///
    ///   ACCEPTED RISK: pricing is not adjusted when the pull fails, so the taker still pays the fee and the
    ///   maker keeps it. Collection is therefore best-effort and the maker controls the trigger through their
    ///   own Aqua balance, wallet balance and allowance. Strategies must be validated before being
    ///   whitelisted, and ProtocolFeeSkipped must be monitored.
    ///
    ///   Both callers reject a zero recipient before reaching here, so the only failures this swallows are
    ///   a maker who cannot cover the fee and a token that refuses the transfer.
    ///
    ///   amountNetPulled is credited only when the pull lands. It reports how much tokenIn the program
    ///   already took out of the maker's ledger, which is what keeps the pre-push check in
    ///   SwapVM._transferIn resolving to "the taker owes exactly amountIn" even though the fee left the
    ///   ledger mid-swap. Crediting it for a pull that never happened would drop that requirement to
    ///   amountIn - fee and let the taker keep the fee instead of the maker.
    function _tryPullFee(Context memory ctx, address to, uint256 feeAmountIn) private {
        if (feeAmountIn == 0) return; // Nothing was skipped, so do not report a skip

        // A parameterless catch is deliberate: it is the only form that catches both the Panic from Aqua's
        // balance underflow and the custom error from the token leg, and it avoids copying revert data that
        // a malicious tokenIn could inflate.
        try _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenIn, feeAmountIn, to) {
            ctx.swap.amountNetPulled += feeAmountIn;
        } catch {
            emit ProtocolFeeSkipped(ctx.query.orderHash, ctx.query.tokenIn, to, feeAmountIn);
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
