// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { StorageSlots } from "../../contracts/libs/StorageSlots.sol";
import { DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { Decay } from "../../contracts/instructions/Decay.sol";
import { InvalidateBit, InvalidateTokenIn, InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import { ValidateSeriesEpoch } from "../../contracts/instructions/SeriesEpochManager.sol";
import { OrderRegistratorLib } from "../../contracts/extensions/OrderRegistrator.sol";

contract StorageSlotsTest is Test {
    function test_StorageSlots() public pure {
        assertEq(StorageSlots.DynamicBalances,         _erc7201("1inch.storage.DynamicBalances"));
        assertEq(StorageSlots.Decay,                   _erc7201("1inch.storage.Decay"));
        assertEq(StorageSlots.InvalidateBit,           _erc7201("1inch.storage.InvalidateBit"));
        assertEq(StorageSlots.InvalidateTokenIn,       _erc7201("1inch.storage.InvalidateTokenIn"));
        assertEq(StorageSlots.InvalidateTokenOut,      _erc7201("1inch.storage.InvalidateTokenOut"));
        assertEq(StorageSlots.ValidateSeriesEpoch,     _erc7201("1inch.storage.ValidateSeriesEpoch"));
        assertEq(StorageSlots.OrderRegistrator,        _erc7201("1inch.storage.OrderRegistrator"));
    }

    function test_StorageSlotsOpcodes() public pure {
        bytes32 slotDynamicBalances;
        DynamicBalances.Storage storage DynamicBalancesStorage = DynamicBalances.store();
        assembly ("memory-safe") {
            slotDynamicBalances := DynamicBalancesStorage.slot
        }
        assertEq(StorageSlots.DynamicBalances, slotDynamicBalances);

        bytes32 slotDecay;
        Decay.Storage storage DecayStorage = Decay.store();
        assembly ("memory-safe") {
            slotDecay := DecayStorage.slot
        }
        assertEq(StorageSlots.Decay, slotDecay);

        bytes32 slotInvalidateBit;
        InvalidateBit.Storage storage InvalidateBitStorage = InvalidateBit.store();
        assembly ("memory-safe") {
            slotInvalidateBit := InvalidateBitStorage.slot
        }
        assertEq(StorageSlots.InvalidateBit, slotInvalidateBit);

        bytes32 slotInvalidateTokenIn;
        InvalidateTokenIn.Storage storage InvalidateTokenInStorage = InvalidateTokenIn.store();
        assembly ("memory-safe") {
            slotInvalidateTokenIn := InvalidateTokenInStorage.slot
        }
        assertEq(StorageSlots.InvalidateTokenIn, slotInvalidateTokenIn);

        bytes32 slotInvalidateTokenOut;
        InvalidateTokenOut.Storage storage InvalidateTokenOutStorage = InvalidateTokenOut.store();
        assembly ("memory-safe") {
            slotInvalidateTokenOut := InvalidateTokenOutStorage.slot
        }
        assertEq(StorageSlots.InvalidateTokenOut, slotInvalidateTokenOut);

        bytes32 slotValidateSeriesEpoch;
        ValidateSeriesEpoch.Storage storage ValidateSeriesEpochStorage = ValidateSeriesEpoch.store();
        assembly ("memory-safe") {
            slotValidateSeriesEpoch := ValidateSeriesEpochStorage.slot
        }
        assertEq(StorageSlots.ValidateSeriesEpoch, slotValidateSeriesEpoch);

        bytes32 slotOrderRegistrator;
        OrderRegistratorLib.Storage storage OrderRegistratorStorage = OrderRegistratorLib.store();
        assembly ("memory-safe") {
            slotOrderRegistrator := OrderRegistratorStorage.slot
        }
        assertEq(StorageSlots.OrderRegistrator, slotOrderRegistrator);
    }

    function _erc7201(string memory id) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
