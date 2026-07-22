// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

/// @notice Library for unified left-to-right instruction args parsing style, e.g. `args.shift(0),asU16()`
/// @dev Order creator is responsible for building args correctly, e.g. using `Instruction.build()`
///   The library does not implement out-of-bounds read validations
/// @dev Bool is parsed as single bit at specified position, bits are counted in backwards order
///   `InstructionBuilder.encodeBool` helper is aligned with the design
library InstructionArgs {
    function at(bytes calldata calls, uint256 shift) internal pure returns (bytes32 res) {
        assembly ("memory-safe") {
            res := calldataload(add(calls.offset, shift))
        }
    }

    function asBool(bytes32 word, uint8 bit) internal pure returns (bool) {
        return (word << bit) & 0x8000000000000000000000000000000000000000000000000000000000000000 != 0;
    }

    function asAddress(bytes32 word) internal pure returns (address) { return address(bytes20(word)); }

    function asU8(bytes32 word) internal pure returns (uint8) { return uint8(bytes1(word)); }
    function asU16(bytes32 word) internal pure returns (uint16) { return uint16(bytes2(word)); }
    function asU24(bytes32 word) internal pure returns (uint24) { return uint24(bytes3(word)); }
    function asU32(bytes32 word) internal pure returns (uint32) { return uint32(bytes4(word)); }
    function asU40(bytes32 word) internal pure returns (uint40) { return uint40(bytes5(word)); }
    function asU48(bytes32 word) internal pure returns (uint48) { return uint48(bytes6(word)); }
    function asU56(bytes32 word) internal pure returns (uint56) { return uint56(bytes7(word)); }
    function asU64(bytes32 word) internal pure returns (uint64) { return uint64(bytes8(word)); }
    function asU72(bytes32 word) internal pure returns (uint72) { return uint72(bytes9(word)); }
    function asU80(bytes32 word) internal pure returns (uint80) { return uint80(bytes10(word)); }
    function asU88(bytes32 word) internal pure returns (uint88) { return uint88(bytes11(word)); }
    function asU96(bytes32 word) internal pure returns (uint96) { return uint96(bytes12(word)); }
    function asU104(bytes32 word) internal pure returns (uint104) { return uint104(bytes13(word)); }
    function asU112(bytes32 word) internal pure returns (uint112) { return uint112(bytes14(word)); }
    function asU120(bytes32 word) internal pure returns (uint120) { return uint120(bytes15(word)); }
    function asU128(bytes32 word) internal pure returns (uint128) { return uint128(bytes16(word)); }
    function asU136(bytes32 word) internal pure returns (uint136) { return uint136(bytes17(word)); }
    function asU144(bytes32 word) internal pure returns (uint144) { return uint144(bytes18(word)); }
    function asU152(bytes32 word) internal pure returns (uint152) { return uint152(bytes19(word)); }
    function asU160(bytes32 word) internal pure returns (uint160) { return uint160(bytes20(word)); }
    function asU168(bytes32 word) internal pure returns (uint168) { return uint168(bytes21(word)); }
    function asU176(bytes32 word) internal pure returns (uint176) { return uint176(bytes22(word)); }
    function asU184(bytes32 word) internal pure returns (uint184) { return uint184(bytes23(word)); }
    function asU192(bytes32 word) internal pure returns (uint192) { return uint192(bytes24(word)); }
    function asU200(bytes32 word) internal pure returns (uint200) { return uint200(bytes25(word)); }
    function asU208(bytes32 word) internal pure returns (uint208) { return uint208(bytes26(word)); }
    function asU216(bytes32 word) internal pure returns (uint216) { return uint216(bytes27(word)); }
    function asU224(bytes32 word) internal pure returns (uint224) { return uint224(bytes28(word)); }
    function asU232(bytes32 word) internal pure returns (uint232) { return uint232(bytes29(word)); }
    function asU240(bytes32 word) internal pure returns (uint240) { return uint240(bytes30(word)); }
    function asU248(bytes32 word) internal pure returns (uint248) { return uint248(bytes31(word)); }
    function asU256(bytes32 word) internal pure returns (uint256) { return uint256(bytes32(word)); }

    function asBytes1(bytes32 word) internal pure returns (bytes1) { return bytes1(word); }
    function asBytes2(bytes32 word) internal pure returns (bytes2) { return bytes2(word); }
    function asBytes3(bytes32 word) internal pure returns (bytes3) { return bytes3(word); }
    function asBytes4(bytes32 word) internal pure returns (bytes4) { return bytes4(word); }
    function asBytes5(bytes32 word) internal pure returns (bytes5) { return bytes5(word); }
    function asBytes6(bytes32 word) internal pure returns (bytes6) { return bytes6(word); }
    function asBytes7(bytes32 word) internal pure returns (bytes7) { return bytes7(word); }
    function asBytes8(bytes32 word) internal pure returns (bytes8) { return bytes8(word); }
    function asBytes9(bytes32 word) internal pure returns (bytes9) { return bytes9(word); }
    function asBytes10(bytes32 word) internal pure returns (bytes10) { return bytes10(word); }
    function asBytes11(bytes32 word) internal pure returns (bytes11) { return bytes11(word); }
    function asBytes12(bytes32 word) internal pure returns (bytes12) { return bytes12(word); }
    function asBytes13(bytes32 word) internal pure returns (bytes13) { return bytes13(word); }
    function asBytes14(bytes32 word) internal pure returns (bytes14) { return bytes14(word); }
    function asBytes15(bytes32 word) internal pure returns (bytes15) { return bytes15(word); }
    function asBytes16(bytes32 word) internal pure returns (bytes16) { return bytes16(word); }
    function asBytes17(bytes32 word) internal pure returns (bytes17) { return bytes17(word); }
    function asBytes18(bytes32 word) internal pure returns (bytes18) { return bytes18(word); }
    function asBytes19(bytes32 word) internal pure returns (bytes19) { return bytes19(word); }
    function asBytes20(bytes32 word) internal pure returns (bytes20) { return bytes20(word); }
    function asBytes21(bytes32 word) internal pure returns (bytes21) { return bytes21(word); }
    function asBytes22(bytes32 word) internal pure returns (bytes22) { return bytes22(word); }
    function asBytes23(bytes32 word) internal pure returns (bytes23) { return bytes23(word); }
    function asBytes24(bytes32 word) internal pure returns (bytes24) { return bytes24(word); }
    function asBytes25(bytes32 word) internal pure returns (bytes25) { return bytes25(word); }
    function asBytes26(bytes32 word) internal pure returns (bytes26) { return bytes26(word); }
    function asBytes27(bytes32 word) internal pure returns (bytes27) { return bytes27(word); }
    function asBytes28(bytes32 word) internal pure returns (bytes28) { return bytes28(word); }
    function asBytes29(bytes32 word) internal pure returns (bytes29) { return bytes29(word); }
    function asBytes30(bytes32 word) internal pure returns (bytes30) { return bytes30(word); }
    function asBytes31(bytes32 word) internal pure returns (bytes31) { return bytes31(word); }
    function asBytes32(bytes32 word) internal pure returns (bytes32) { return bytes32(word); }
}
