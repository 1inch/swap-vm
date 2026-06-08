// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library WhitelistArgsBuilder {
    error WhitelistEmptyList();

    function buildWhitelistSingleTaker(address allowedTaker) internal pure returns (bytes memory) {
        return abi.encodePacked(allowedTaker);
    }

    function parseWhitelistSingleTaker(bytes calldata args) internal pure returns (address allowedTaker) {
        assembly ("memory-safe") {
            allowedTaker := shr(96, calldataload(args.offset))
        }
    }

    /// @dev Due to args length limitiation, for multiple takers only last 80 bits of each address are packed
    function buildWhitelistMultipleTakers(address[] memory allowedTakers) internal pure returns (bytes memory) {
        require(allowedTakers.length > 0, WhitelistEmptyList());

        uint256 len = allowedTakers.length * 10;
        bytes memory res = new bytes(len);

        assembly ("memory-safe") {
            let ptr := add(allowedTakers, add(32, 22))
            let dst := add(res, 32)
            let fin := add(dst, len)
            for { } lt(dst, fin) { } {
                mcopy(dst, ptr, 10)
                ptr := add(ptr, 32)
                dst := add(dst, 10)
            }
        }

        return res;
    }

    function parseWhitelistMultipleTakers(bytes calldata args, uint256 id) internal pure returns (uint80 allowedTaker) {
        assembly ("memory-safe") {
            allowedTaker := shr(176, calldataload(add(args.offset, mul(id, 10))))
        }
    }

    function wrapToPackedAddress(address taker) internal pure returns (uint80 packed) {
        packed = uint80(uint160(taker));
    }
}

/// @notice Set of functions for Taker validation
/// @dev Taker whitelist functionality, the opcodes can be included in whatever place of the program
/// @dev Partial account validation trade-off:
/// - For packing multiple takers whitelist, only last 80 bits of each address are used
/// - Mining 80 bits of Ethereum address is not truly impossible but would take years of millions GPUs time
/// - Consider theoretical possibility of such address being mined for an address known for years,
///   avoid orders with "free money" relying on the `_whitelistMultipleTakers` opcode
contract Whitelist {
    using WhitelistArgsBuilder for bytes;

    error WhitelistInvalidTaker();

    /// @notice Allows order to be executed only by the specified Taker
    /// @param args.allowedTaker | 20 bytes
    function _whitelistSingleTaker(Context memory ctx, bytes calldata args) internal pure {
        address allowedTaker = args.parseWhitelistSingleTaker();
        require(ctx.query.taker == allowedTaker, WhitelistInvalidTaker());
    }

    /// @notice Allows order to be executed only by one of specified Takers
    /// @param args.allowedTakers[N] | 10 * N bytes, last 10 bytes of each address are used
    function _whitelistMultipleTakers(Context memory ctx, bytes calldata args) internal pure {
        uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);

        unchecked {
            uint256 i = args.length / 10;
            while (i-- > 0) {
                if (sender == args.parseWhitelistMultipleTakers(i)) return;
            }
        }

        revert WhitelistInvalidTaker();
    }
}
