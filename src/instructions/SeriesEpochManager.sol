// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

library SeriesEpochManagerArgsBuilder {
    using Calldata for bytes;

    error SeriesEpochManagerMissingSeriesId();
    error SeriesEpochManagerMissingEpoch();

    function buildEpochValidation(uint32 seriesId, uint32 epoch) internal pure returns (bytes memory) {
        return abi.encodePacked(seriesId, epoch);
    }

    function parse(bytes calldata args) internal pure returns (uint256 seriesId, uint256 epoch) {
        seriesId = uint32(bytes4(args.slice(0, 4, SeriesEpochManagerMissingSeriesId.selector)));
        epoch = uint32(bytes4(args.slice(4, 8, SeriesEpochManagerMissingEpoch.selector)));
    }
}

/**
 * @notice Managing epoch for series of orders, an order is executable only at specified epoch
 * @dev Each maker keeps an independent, monotonically increasing epoch per `seriesId`
 * An order pins itself to a `(seriesId, epoch)` via the `_validateSeriesEpochXD` instruction
 * - The maker can cancel a whole batch at once by advancing that series' epoch
 * - The maker can plan orders for future epochs
 * - The maker can move over epochs sequentially or skip up to 254 epochs
 */
contract SeriesEpochManager {
    using ContextLib for Context;

    error SeriesEpochManagerWrongEpoch(address maker, uint256 seriesId, uint256 expectedEpoch, uint256 currentEpoch);
    error SeriesEpochManagerAdvanceEpochFailed();

    /// @notice Current epoch per maker per series. Orders pinned to a lower epoch are invalidated
    mapping(address maker => mapping(uint256 seriesId => uint256 epoch)) public seriesEpoch;

    /// @notice Advances the caller's epoch for `seriesId` by one (invalidates the current epoch)
    function seriesEpochIncrease(uint256 seriesId) external {
        unchecked {
            seriesEpoch[msg.sender][seriesId]++;
        }
    }

    /// @notice Advances the caller's epoch for `seriesId` by `amount` (invalidates multiple epochs at once)
    /// @dev `amount` is bounded to [1, 255]
    function seriesEpochAdvance(uint256 seriesId, uint256 amount) external {
        if (amount == 0 || amount > 255) revert SeriesEpochManagerAdvanceEpochFailed();
        unchecked {
            uint256 newEpoch = seriesEpoch[msg.sender][seriesId] + amount;
            seriesEpoch[msg.sender][seriesId] = newEpoch;
        }
    }

    /// @notice Requires the maker's current epoch for the order's series to match the epoch specified in the order
    /// @dev The instruction does not affect swap registers or state, it could be used in whatever place of the program
    /// @dev The instruction is compatible with any order type
    /// @param args.seriesId | 4 bytes (uint32)
    /// @param args.epoch    | 4 bytes (uint32)
    function _validateSeriesEpochXD(Context memory ctx, bytes calldata args) internal view {
        (uint256 seriesId, uint256 expectedEpoch) = SeriesEpochManagerArgsBuilder.parse(args);

        uint256 currentEpoch = seriesEpoch[ctx.query.maker][seriesId];
        require(currentEpoch == expectedEpoch, SeriesEpochManagerWrongEpoch(ctx.query.maker, seriesId, expectedEpoch, currentEpoch));
    }
}
