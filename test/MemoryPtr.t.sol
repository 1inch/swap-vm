// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test, stdError } from "forge-std/Test.sol";

import { MemoryPtr, MemoryPtrLib } from "../src/libs/MemoryPtr.sol";

/**
 * @title MemoryPtr
 * @notice Tests for MemoryPtrLib allocation, push, patch, skip and resolve primitives
 */
contract MemoryPtrTest is Test {
    using MemoryPtrLib for MemoryPtr;

    address constant PUSH_ADDR = address(uint160(0x1122334455667788990011223344556677889900));
    address constant PATCH_ADDR = address(uint160(0xAAbbCCDdeEFf00112233445566778899aABBcCDd));

    function test_AllocEmpty() public pure {
        assertEq(MemoryPtrLib.alloc(0).resolve(), "");
    }

    function test_AllocZeroized() public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(5);
        assertEq(ptr.skip(5).resolve(), hex"0000000000");
    }

    function test_PushEveryOverload() public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(1 + 1 + 20 + 12 + 5 + 32);
        ptr = ptr
            .push(uint8(0x01))
            .push(bytes1(0x02))
            .push(PUSH_ADDR)
            .push(bytes32(bytes12(0x0A0B0C0D0E0F101112131415)), 12)
            .push(uint256(0x1122334455), 5)
            .push(type(uint256).max, 32);

        assertEq(ptr.resolve(), abi.encodePacked(
            uint8(0x01),
            bytes1(0x02),
            PUSH_ADDR,
            bytes12(0x0A0B0C0D0E0F101112131415),
            uint40(0x1122334455),
            type(uint256).max
        ));
    }

    function testFuzz_PushCalldata(bytes calldata data) public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(data.length);
        assertEq(ptr.push(data).resolve(), data);
    }

    function test_PushMem() public pure {
        bytes memory data = abi.encodePacked(type(uint256).max, uint16(0x0102));
        MemoryPtr ptr = MemoryPtrLib.alloc(2 + data.length);
        ptr = ptr.push(uint256(0xBEEF), 2).pushMem(data);
        assertEq(ptr.resolve(), abi.encodePacked(uint16(0xBEEF), data));
    }

    function test_PatchEveryOverload() public pure {
        MemoryPtr start = MemoryPtrLib.alloc(20 + 1 + 12 + 1 + 2);
        MemoryPtr ptr = start.skip(36);

        start.patch(PATCH_ADDR);
        start.skip(20).patch(bytes1(0xAA));
        start.skip(21).patch(bytes32(bytes12(0x0F0E0D0C0B0A090807060504)), 12);
        start.skip(33).patch(uint8(0xBB));
        start.skip(34).patch(uint256(0xCCDD), 2);

        assertEq(ptr.resolve(), abi.encodePacked(
            PATCH_ADDR,
            bytes1(0xAA),
            bytes12(0x0F0E0D0C0B0A090807060504),
            uint8(0xBB),
            uint16(0xCCDD)
        ));
    }

    function test_PatchPreservesNeighbors() public pure {
        MemoryPtr start = MemoryPtrLib.alloc(8);
        MemoryPtr ptr = start.push(type(uint64).max, 8);

        start.skip(2).patch(uint256(0), 4);

        assertEq(ptr.resolve(), hex"ffff00000000ffff");
    }

    function test_ResolveWithSkip() public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(5);
        assertEq(ptr.push(uint8(0xFF)).skip(4).resolve(), hex"ff00000000");
    }

    function test_ResolveShrinkUntouched() public pure {
        (bytes memory slice, uint256 shrink) = MemoryPtrLib.alloc(4).resolveShrink();
        assertEq(shrink, 4);
        assertEq(slice, "");
    }

    function test_ResolveShrinkWithSkip() public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(10);
        (bytes memory slice, uint256 shrink) = ptr.push(uint256(0x0102), 2).skip(3).resolveShrink();
        assertEq(shrink, 5);
        assertEq(slice, hex"0102000000");
    }

    function test_ResolveShrinkExact() public pure {
        MemoryPtr ptr = MemoryPtrLib.alloc(2);
        (bytes memory slice, uint256 shrink) = ptr.push(uint256(0x0102), 2).resolveShrink();
        assertEq(shrink, 0);
        assertEq(slice, hex"0102");
    }

    function test_Sub() public pure {
        MemoryPtr start = MemoryPtrLib.alloc(10);
        MemoryPtr ptr = start.push(uint256(1), 4);

        assertEq(start.sub(start), 0);
        assertEq(ptr.sub(start), 4);
        assertEq(ptr.skip(2).sub(start), 6);
    }

    function test_ConsecutiveSlices() public pure {
        MemoryPtr a = MemoryPtrLib.alloc(3);
        bytes memory between = abi.encodePacked(type(uint256).max);
        MemoryPtr c = MemoryPtrLib.alloc(3);

        // Full-word mstores of both pushes must land in own slack, not in the neighbor slices
        a = a.push(uint256(0x010203), 3);
        c = c.push(uint256(0x040506), 3);

        assertEq(a.resolve(), hex"010203");
        assertEq(between, abi.encodePacked(type(uint256).max));
        assertEq(c.resolve(), hex"040506");
    }

    function test_RevertAllocTooMuch() public {
        vm.expectRevert(abi.encodeWithSelector(MemoryPtrLib.MemoryPtrAllocTooMuch.selector, uint256(1) << 64));
        this.allocate(uint256(1) << 64);
    }

    function test_RevertSkipTooMuch() public {
        vm.expectRevert(abi.encodeWithSelector(MemoryPtrLib.MemoryPtrSkipTooMuch.selector, uint256(1) << 24));
        this.skipMuch(uint256(1) << 24);
    }

    function test_RevertResolveUnderfilled() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrStrictResolveFailed.selector);
        this.resolveUnderfilled();
    }

    function test_RevertResolveOverfilled() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrStrictResolveFailed.selector);
        this.resolveOverfilled();
    }

    function test_RevertResolveShrinkOverfilled() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrWriteOutOfBounds.selector);
        this.resolveShrinkOverfilled();
    }

    function test_RevertPatchOutOfBounds() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrWriteOutOfBounds.selector);
        this.patchOutOfBounds();
    }

    function test_RevertPatch8OutOfBounds() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrWriteOutOfBounds.selector);
        this.patch8OutOfBounds();
    }

    function test_RevertPushUintOversize() public {
        vm.expectRevert(stdError.arithmeticError);
        this.pushUint(1, 33);
    }

    function test_RevertPatchUintOversize() public {
        vm.expectRevert(stdError.arithmeticError);
        this.patchUint(1, 33);
    }

    function test_RevertSubBaseMismatch() public {
        vm.expectPartialRevert(MemoryPtrLib.MemoryPtrBaseMismatch.selector);
        this.subForeignBases();
    }

    function test_RevertSubUnderflow() public {
        vm.expectRevert(stdError.arithmeticError);
        this.subReversed();
    }

    // Externals to make internal library reverts observable by `expectRevert`

    function allocate(uint256 length) external pure {
        MemoryPtrLib.alloc(length);
    }

    function skipMuch(uint256 size) external pure {
        MemoryPtrLib.alloc(0).skip(size);
    }

    function resolveUnderfilled() external pure {
        MemoryPtrLib.alloc(4).resolve();
    }

    function resolveOverfilled() external pure {
        MemoryPtrLib.alloc(4).push(uint256(1), 32).resolve();
    }

    function resolveShrinkOverfilled() external pure {
        MemoryPtrLib.alloc(4).push(uint256(1), 32).resolveShrink();
    }

    function patchOutOfBounds() external pure {
        MemoryPtrLib.alloc(4).patch(uint256(1), 8);
    }

    function patch8OutOfBounds() external pure {
        MemoryPtrLib.alloc(0).patch(uint8(1));
    }

    function pushUint(uint256 value, uint8 size) external pure {
        MemoryPtrLib.alloc(64).push(value, size);
    }

    function patchUint(uint256 value, uint8 size) external pure {
        MemoryPtrLib.alloc(64).patch(value, size);
    }

    function subForeignBases() external pure {
        MemoryPtr a = MemoryPtrLib.alloc(4);
        MemoryPtr b = MemoryPtrLib.alloc(4);
        b.sub(a);
    }

    function subReversed() external pure {
        MemoryPtr a = MemoryPtrLib.alloc(4);
        MemoryPtr b = MemoryPtrLib.alloc(4);
        a.sub(b);
    }
}
