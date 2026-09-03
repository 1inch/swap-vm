// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";
import { StaticBalances } from "../instructions/Balances.sol";
import { LimitSwap } from "../instructions/LimitSwap.sol";
import { XYCConcentrateSwap } from "../instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../instructions/FeeFlat.sol";
import {
    OnlyTakerTokenBalanceNonZero,
    OnlyTakerTokenBalanceGte,
    OnlyTakerTokenSupplyShareGte,
    OnlyTxOriginTokenBalanceNonZero
} from "../instructions/TokenValidators.sol";
import { Deadline, Salt } from "../instructions/Controls.sol";
import { ValidateSeriesEpoch } from "../instructions/SeriesEpochManager.sol";

/// @dev Library for on-chain orders validation
///   Prefixes does not impact amounts calculation, so arbitrary allowed
///   Proposed strategies holds some invariants such as maker min/max swap rate
library Strategies {
    using InstructionArgs for bytes;

    error PrefixInvalidLength(uint256 length, uint256 expected);
    error PrefixUnregistered(uint8 opcode);

    struct LimitOrder {
        uint256 balanceA;
        uint256 balanceB;
        bool direction;
    }

    struct XYCConcentrateOrder {
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint24 feeBps;
    }

    uint256 private constant _prefixBitmap =
        (1 << uint256(OnlyTakerTokenBalanceNonZero.opcode)) |
        (1 << uint256(OnlyTakerTokenBalanceGte.opcode)) |
        (1 << uint256(OnlyTakerTokenSupplyShareGte.opcode)) |
        (1 << uint256(OnlyTxOriginTokenBalanceNonZero.opcode)) |
        (1 << uint256(Deadline.opcode)) |
        (1 << uint256(Salt.opcode)) |
        (1 << uint256(ValidateSeriesEpoch.opcode));

    /// @notice Prefixes are validation-only opcodes which do not change registers
    ///   Wrongly built prefix instructions do not affect strategy calculations,
    ///   so checking only opcode is in prefix bitmap and length consistency is enough
    function _checkPrefix(bytes[] calldata instructions) private pure returns (uint256 prefixSize) {
        for (uint256 i; i < instructions.length; i++) {
            bytes calldata instruction = instructions[i];
            uint8 opcode = instruction.at(0).asU8();
            uint256 length = 2 + instruction.at(1).asU8();

            require(instruction.length == length, PrefixInvalidLength(instruction.length, length));
            require(_prefixBitmap & (1 << opcode) != 0, PrefixUnregistered(opcode));

            prefixSize += instruction.length;
        }
    }

    function buildLimitOrder(
        bytes[] calldata prefix,
        LimitOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            StaticBalances.sizeOf(args.balanceA, args.balanceB) +
            LimitSwap.sizeOf(args.direction)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = StaticBalances.build(ptr, args.balanceA, args.balanceB);
        ptr = LimitSwap.build(ptr, args.direction);

        return ptr.resolve();
    }

    function buildXYCConcentrateOrder(
        bytes[] calldata prefix,
        XYCConcentrateOrder calldata args
    ) internal pure returns (bytes memory) {
        MemoryPtr ptr = MemoryPtrLib.alloc(
            _checkPrefix(prefix) +
            FeeFlatIn.sizeOf(args.feeBps) +
            XYCConcentrateSwap.sizeOf(args.sqrtPriceMin, args.sqrtPriceMax)
        );

        for (uint256 i; i < prefix.length; i++) ptr = ptr.push(prefix[i]);
        ptr = FeeFlatIn.build(ptr, args.feeBps);
        ptr = XYCConcentrateSwap.build(ptr, args.sqrtPriceMin, args.sqrtPriceMax);

        return ptr.resolve();
    }
}
