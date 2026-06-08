// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IMakerHooks } from "../../src/interfaces/IMakerHooks.sol";

import { IOrderMixin } from "@1inch/limit-order-protocol/interfaces/IOrderMixin.sol";
import { IPreInteraction } from "@1inch/limit-order-protocol/interfaces/IPreInteraction.sol";
import { IPostInteraction } from "@1inch/limit-order-protocol/interfaces/IPostInteraction.sol";

/// @title  InteractionRecorderMock
/// @notice A single mock that satisfies BOTH platforms' interaction interfaces so the same contract can
///         be the maker's interaction target on LOP (IPreInteraction/IPostInteraction) and the maker's
///         hook target on SwapVM (IMakerHooks). Every call appends the maker-supplied data payload to a
///         per-hook list, so a test can snapshot the count, run an order, and assert exactly one new
///         record with the expected bytes appeared.
/// @dev    The recorded payload is the maker-side data argument: LOP's `extraData` and SwapVM's
///         `makerData`. The builder feeds the same bytes to both, so the two platforms record the same
///         value — giving a clean differential check that interactions fired with the intended data.
contract InteractionRecorderMock is IMakerHooks, IPreInteraction, IPostInteraction {
    // Hook identity tags (keyed in the records mapping).
    bytes32 public constant PRE_INTERACTION = keccak256("LOP.preInteraction");
    bytes32 public constant POST_INTERACTION = keccak256("LOP.postInteraction");
    bytes32 public constant PRE_TRANSFER_IN = keccak256("VM.preTransferIn");
    bytes32 public constant POST_TRANSFER_IN = keccak256("VM.postTransferIn");
    bytes32 public constant PRE_TRANSFER_OUT = keccak256("VM.preTransferOut");
    bytes32 public constant POST_TRANSFER_OUT = keccak256("VM.postTransferOut");

    /// @notice tag => ordered list of maker-supplied data payloads, one per call.
    mapping(bytes32 tag => bytes[] payloads) private _records;

    function recordsLength(bytes32 tag) external view returns (uint256) {
        return _records[tag].length;
    }

    function recordAt(bytes32 tag, uint256 index) external view returns (bytes memory) {
        return _records[tag][index];
    }

    function lastRecord(bytes32 tag) external view returns (bytes memory) {
        bytes[] storage list = _records[tag];
        require(list.length > 0, "no records");
        return list[list.length - 1];
    }

    // ---------------------------------------------------------------------------------------------
    // LOP maker interactions
    // ---------------------------------------------------------------------------------------------

    function preInteraction(
        IOrderMixin.Order calldata,
        bytes calldata,
        bytes32,
        address,
        uint256,
        uint256,
        uint256,
        bytes calldata extraData
    ) external {
        _records[PRE_INTERACTION].push(extraData);
    }

    function postInteraction(
        IOrderMixin.Order calldata,
        bytes calldata,
        bytes32,
        address,
        uint256,
        uint256,
        uint256,
        bytes calldata extraData
    ) external {
        _records[POST_INTERACTION].push(extraData);
    }

    // ---------------------------------------------------------------------------------------------
    // SwapVM maker hooks
    // ---------------------------------------------------------------------------------------------

    function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata makerData, bytes calldata)
        external
    {
        _records[PRE_TRANSFER_IN].push(makerData);
    }

    function postTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata makerData, bytes calldata)
        external
    {
        _records[POST_TRANSFER_IN].push(makerData);
    }

    function preTransferOut(address, address, address, address, uint256, uint256, bytes32, bytes calldata makerData, bytes calldata)
        external
    {
        _records[PRE_TRANSFER_OUT].push(makerData);
    }

    function postTransferOut(address, address, address, address, uint256, uint256, bytes32, bytes calldata makerData, bytes calldata)
        external
    {
        _records[POST_TRANSFER_OUT].push(makerData);
    }
}
