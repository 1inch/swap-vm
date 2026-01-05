// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Test } from "forge-std/Test.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";

contract ProtocolFeeProviderMockTest is Test {
    ProtocolFeeProviderMock private feeProvider;
    address private feeRecipient = feeRecipient = vm.addr(0x1234);
    uint32 private constant INITIAL_FEE_BPS = 0.002e9; // 0.2% in 1e9 scale
    bytes32 private constant DUMMY_ORDER_HASH = keccak256("DUMMY_ORDER");

    function setUp() public {
        feeProvider = new ProtocolFeeProviderMock(
            INITIAL_FEE_BPS,           // feeBps: 0.2% in 1e9 scale
            address(feeRecipient), // address to receive fees
            address(this)      // owner who can update settings
        );
    }

    function testGetProtocolFeeParams() public {
        vm.record();
        (uint32 feeBps, address to) = feeProvider.getFeeBpsAndRecipient(
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
        assertEq(to, address(feeRecipient));
    }

    function testSetProtocolFeeParams() public {
        uint32 feeBpsNew = 0.003e9; // 0.3% in 1e9 scale
        address feeRecipientNew = address(0x5678);

        vm.record();
        feeProvider.setFeeBpsAndRecipient(feeBpsNew, feeRecipientNew);
        (uint32 feeBps, address to) = feeProvider.getFeeBpsAndRecipient(
            DUMMY_ORDER_HASH,
            address(0),
            address(0),
            address(0),
            address(0),
            false
        );
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(feeProvider));
        assertEq(reads.length, 3, "Three state read expected"); // 2 reads for owner check + 1 read for getter
        assertEq(writes.length, 1, "One state write expected in setter");

        assertEq(feeBps, feeBpsNew);
        assertEq(to, feeRecipientNew);
    }

    function testSetProtocolFeeParams_NotOwner() public {
        vm.prank(address(0x5678));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x5678)));
        feeProvider.setFeeBpsAndRecipient(0.003e9, address(0x1234));
    }

}
