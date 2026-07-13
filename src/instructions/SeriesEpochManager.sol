// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { StorageSlots } from "../libs/StorageSlots.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice ValidateSeriesEpoch opcode, requires the maker's current epoch for the series to match the epoch specified in the order
///   Each maker keeps an independent, monotonically increasing epoch per seriesId, advancing a series epoch cancels the whole batch
///   of orders pinned to it, orders can be planned for future epochs
/// @dev Encoding: [uint32 seriesId, uint32 epoch]
library ValidateSeriesEpoch {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error ValidateSeriesEpochWrongEpoch(address maker, uint256 seriesId, uint256 expectedEpoch, uint256 currentEpoch);

    Opcode constant opcode = Opcode.ValidateSeriesEpoch;

    function build(uint32 seriesId, uint32 epoch) internal pure returns (bytes memory) {
        bytes memory args = abi.encodePacked(seriesId, epoch);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint32 seriesId, uint32 epoch) {
        seriesId = args.at(0).asU32();
        epoch = args.at(4).asU32();
    }

    struct Storage {
        mapping(address maker => mapping(uint256 seriesId => uint256)) epoch;
    }

    function store() internal pure returns (Storage storage $) {
        bytes32 slot = StorageSlots.ValidateSeriesEpoch;
        assembly { $.slot := slot }
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        ValidateSeriesEpoch.Storage storage $ = ValidateSeriesEpoch.store();
        (uint32 seriesId, uint32 expectedEpoch) = parse(args);

        uint256 currentEpoch = $.epoch[ctx.query.maker][seriesId];
        require(currentEpoch == expectedEpoch, ValidateSeriesEpochWrongEpoch(ctx.query.maker, seriesId, expectedEpoch, currentEpoch));
    }
}

contract ValidateSeriesEpochExternal {
    error SeriesEpochAdvanceFailed();

    event SeriesEpochIncreased(address indexed maker, uint256 indexed seriesId, uint256 newEpoch);

    function seriesEpoch(address maker, uint256 seriesId) external view returns (uint256) {
        ValidateSeriesEpoch.Storage storage $ = ValidateSeriesEpoch.store();
        return $.epoch[maker][seriesId];
    }

    /// @notice Advances the caller's epoch for seriesId by one (invalidates the current epoch)
    function seriesEpochIncrease(uint256 seriesId) external {
        ValidateSeriesEpoch.Storage storage $ = ValidateSeriesEpoch.store();

        unchecked {
            uint256 newEpoch = ++$.epoch[msg.sender][seriesId];
            emit SeriesEpochIncreased(msg.sender, seriesId, newEpoch);
        }
    }

    /// @notice Advances the caller's epoch for seriesId by amount in [1, 255] (invalidates multiple epochs at once)
    function seriesEpochAdvance(uint256 seriesId, uint8 amount) external {
        require(amount > 0, SeriesEpochAdvanceFailed());
        ValidateSeriesEpoch.Storage storage $ = ValidateSeriesEpoch.store();

        unchecked {
            uint256 newEpoch = $.epoch[msg.sender][seriesId] + amount;
            $.epoch[msg.sender][seriesId] = newEpoch;
            emit SeriesEpochIncreased(msg.sender, seriesId, newEpoch);
        }
    }
}
