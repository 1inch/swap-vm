// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library WhitelistArgsBuilder {
    error WhitelistEmptyList();
    error WhitelistListsLengthMismatch();

    /// @notice Pack address for comparison
    function buildPrivateOrder(address allowedTaker) internal pure returns (bytes memory) {
        return abi.encodePacked(wrapToPackedAddress(allowedTaker));
    }

    /// @notice Parse packed address
    function parsePrivateOrder(bytes calldata args) internal pure returns (uint80 allowedTaker) {
        assembly ("memory-safe") {
            allowedTaker := shr(176, calldataload(args.offset))
        }
    }

    /// @notice Pack program counter and whitelist
    function buildWhitelistCoequal(uint16 pc, address[] memory allowedTakers) internal pure returns (bytes memory args) {
        require(allowedTakers.length > 0, WhitelistEmptyList());

        args = abi.encodePacked(pc);
        for (uint256 i; i < allowedTakers.length; i++) {
            args = abi.encodePacked(args, wrapToPackedAddress(allowedTakers[i]));
        }
    }

    /// @notice Parse encoded program counter
    function parseWhitelistCoequalPC(bytes calldata args) internal pure returns (uint256 pcs) {
        assembly ("memory-safe") {
            pcs := shr(240, calldataload(args.offset))
        }
    }

    /// @notice Parse specific whitelist entry
    /// @dev Requires args to be shifted by 2 bytes
    function parseWhitelistCoequalIx(bytes calldata args, uint256 id) internal pure returns (uint80 allowedTaker) {
        assembly ("memory-safe") {
            allowedTaker := shr(176, calldataload(add(args.offset, mul(id, 10))))
        }
    }

    /// @notice Pack program counter and sequentially growing time-dependent whitelist
    function buildWhitelistSequential(uint16 pc, uint40 start, address[] memory allowedTakers, uint16[] memory durations) internal pure returns (bytes memory args) {
        require(allowedTakers.length > 0, WhitelistEmptyList());
        require(allowedTakers.length == durations.length, WhitelistListsLengthMismatch());

        args = abi.encodePacked(pc, start);
        for (uint256 i = 0; i < allowedTakers.length; i++) {
            args = abi.encodePacked(args, durations[i], wrapToPackedAddress(allowedTakers[i]));
        }
    }

    /// @notice Parse encoded program counter and whitelist start timestamp
    function parseWhitelistSequentialStartPC(bytes calldata args) internal pure returns (uint40 ts, uint256 pcs) {
        assembly ("memory-safe") {
            ts := shr(200, calldataload(args.offset))
            pcs := shr(240, calldataload(args.offset))
        }
    }

    /// @notice Parse specific whitelist entry
    /// @dev Requires args to be shifted by 7 bytes
    function parseWhitelistSequentialIx(bytes calldata args, uint256 id) internal pure returns (uint80 allowedTaker, uint256 duration) {
        assembly ("memory-safe") {
            let word := calldataload(add(args.offset, mul(id, 12)))
            allowedTaker := shr(160, word)
            duration := shr(240, word)
        }
    }

    /// @notice Pack address helper
    /// @dev Packing only last 10 bytes of address
    function wrapToPackedAddress(address taker) internal pure returns (uint80 packed) {
        packed = uint80(uint160(taker));
    }
}

/// @notice Set of functions for Taker validation
/// @dev Partial account validation trade-off:
/// - For packing taker addresses, only last 80 bits of each address are used
/// - Mining 80 bits of an Ethereum address is not truly impossible but would take millions of GPU-years time
/// - Consider theoretical possibility of such address being mined for an address known for years,
///   avoid orders with "free money" relying on the opcodes
contract Whitelist {
    using WhitelistArgsBuilder for bytes;
    using Calldata for bytes;

    error WhitelistInvalidTaker();
    error WhitelistAllowedTimeViolation();

    /// @notice Allows order to be executed only by the specified Taker
    /// @param args.allowedTaker | 10 bytes, last 10 bytes of address are used
    function _privateOrder(Context memory ctx, bytes calldata args) internal pure {
        uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
        uint80 allowedTaker = args.parsePrivateOrder();

        require(sender == allowedTaker, WhitelistInvalidTaker());
    }

    /// @notice Conditional opcode, jump to specified program counter if Taker is whitelisted
    ///   Continue execution normally if Taker is not whitelisted
    /// @param args.pc               | 2 bytes, program counter to jump to
    /// @param args.allowedTakers[N] | 10 * N bytes, last 10 bytes of each address are used
    function _whitelistCoequal(Context memory ctx, bytes calldata args) internal pure {
        uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
        bytes calldata list = args.slice(2);

        unchecked {
            uint256 i = list.length / 10;
            while (i-- > 0) {
                if (sender == list.parseWhitelistCoequalIx(i)) {
                    ctx.vm.nextPC = args.parseWhitelistCoequalPC();
                    return;
                }
            }
        }
    }

    /// @notice Conditional sequentially growing time-dependent whitelist
    ///   Jump to specified program counter if Taker is whitelisted and time-unlocked
    ///   Continue normally if Taker is not whitelisted and the whole whitelist-exclusive period has passed
    ///   Otherwise revert
    /// @dev Whitelist is empty before `start`
    ///   At timepoint `ts` such that `start + Σ(duration[0:k-1]) <= ts < start + Σ(duration[0:k])` whitelist has `k` items unlocked
    /// @param args.pc               | 2 bytes, program counter to jump to
    /// @param args.start            | 5 bytes, whitelist start timestamp
    /// @param args.allowedTakers[N] | 10 * N bytes, last 10 bytes of each address are used
    /// @param args.durations[N]     | 2 * N bytes, time interval before the next whitelist item is unlocked
    function _whitelistSequential(Context memory ctx, bytes calldata args) internal view {
        uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
        (uint40 start, uint256 pc) = args.parseWhitelistSequentialStartPC();
        uint256 timeLeft = block.timestamp;

        unchecked {
            if (timeLeft < start) revert WhitelistAllowedTimeViolation();
            timeLeft -= start;

            bytes calldata list = args.slice(7);

            uint256 i;
            uint256 length = list.length / 12;

            while (i < length) {
                (uint80 allowedTaker, uint256 duration) = list.parseWhitelistSequentialIx(i++);

                if (sender == allowedTaker) {
                    ctx.vm.nextPC = pc;
                    return;
                }

                if (duration > timeLeft) revert WhitelistAllowedTimeViolation();
                timeLeft -= duration;
            }
        }
    }
}
