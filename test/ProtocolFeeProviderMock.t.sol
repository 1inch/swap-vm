// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Test } from "forge-std/Test.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";

contract ProtocolFeeProviderMockTest is Test {
    ProtocolFeeProviderMock private feeProvider;
    address private feeRecipient = vm.addr(0x1234);
    uint24 private constant INITIAL_FEE_BPS = 0.002e7; // 0.2% in 1e7 scale
    uint24 private constant INITIAL_SURPLUS_BPS = 0.1e7; // 10% in 1e7 scale
    bytes32 private constant DUMMY_ORDER_HASH = keccak256("DUMMY_ORDER");

    function setUp() public {
        feeProvider = new ProtocolFeeProviderMock(
            INITIAL_FEE_BPS,       // feeBps: 0.2% in 1e7 scale
            INITIAL_SURPLUS_BPS,   // surplusBps: 10% in 1e7 scale
            address(feeRecipient), // address to receive fees
            address(this)          // owner who can update settings
        );
    }

    function test_GetProtocolFeeParams() public {
        vm.record();
        (address to, uint24 feeBps, uint24 surplusBps) = feeProvider.getRecipientAndFees(
            DUMMY_ORDER_HASH,
            address(0),
            address(0),
            address(0),
            address(0),
            false
        );
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(feeProvider));
        assertEq(reads.length, 1, "One state read expected");
        assertEq(writes.length, 0, "No state writes expected");

        assertEq(feeBps, INITIAL_FEE_BPS);
        assertEq(surplusBps, INITIAL_SURPLUS_BPS);
        assertEq(to, address(feeRecipient));
    }

    function test_SetProtocolFeeParams() public {
        uint24 feeBpsNew = 0.003e7; // 0.3% in 1e7 scale
        uint24 surplusBpsNew = 0.2e7; // 20% in 1e7 scale
        address feeRecipientNew = address(0x5678);

        vm.record();
        feeProvider.setRecipientAndFees(feeRecipientNew, feeBpsNew, surplusBpsNew);
        (address to, uint24 feeBps, uint24 surplusBps) = feeProvider.getRecipientAndFees(
            DUMMY_ORDER_HASH,
            address(0),
            address(0),
            address(0),
            address(0),
            false
        );
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(feeProvider));
        assertEq(reads.length, 4, "Four state reads expected"); // owner check + packed-struct read-modify-write + getter
        assertEq(writes.length, 1, "One state write expected in setter");

        assertEq(feeBps, feeBpsNew);
        assertEq(surplusBps, surplusBpsNew);
        assertEq(to, feeRecipientNew);
    }

    function test_SetProtocolFeeParams_NotOwner() public {
        vm.prank(address(0x5678));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x5678)));
        feeProvider.setRecipientAndFees(address(0x1234), 0.003e7, 0);
    }

}
