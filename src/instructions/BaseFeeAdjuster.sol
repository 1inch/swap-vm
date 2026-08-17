// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice BaseFeeAdjusterBalanceIn opcode, price adjustment based on network gas costs with price percent cap
/// @dev Encoding: [uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps]
/// @dev Supports only single direction swaps, eth price specified in token in
/// @dev Adjustment is applied to the total or remaining balance depending on ordering with InvalidateTokenOut opcode
library BaseFeeAdjusterBalanceIn {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error BaseFeeAdjusterCapOutOfRange(uint24 capBps);

    Opcode constant opcode = Opcode.BaseFeeAdjusterBalanceIn;

    uint256 constant ONE = 1e18;
    uint256 constant BPS = 1e7;

    function build(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) internal pure returns (bytes memory) {
        require(capBps < BPS, BaseFeeAdjusterCapOutOfRange(capBps));

        bytes memory args = abi.encodePacked(baseGasPrice, ethPrice, gasAmount, capBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) {
        baseGasPrice = args.at(0).asU64();
        ethPrice = args.at(8).asU96();
        gasAmount = args.at(20).asU24();
        capBps = args.at(23).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) = parse(args);

        if (block.basefee <= baseGasPrice) return;

        uint256 tokenInDiscount = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        uint256 maxTokenInDiscount = ctx.swap.balanceIn * capBps / BPS;
        if (tokenInDiscount > maxTokenInDiscount) tokenInDiscount = maxTokenInDiscount;

        ctx.swap.balanceIn -= tokenInDiscount;
    }
}

/// @notice BaseFeeAdjusterBalanceOut opcode, price adjustment based on network gas costs with price percent cap
/// @dev Encoding: [uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps]
/// @dev Supports only single direction swaps, eth price specified in token out
/// @dev Adjustment is applied to the total or remaining balance depending on ordering with InvalidateTokenIn opcode
library BaseFeeAdjusterBalanceOut {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    error BaseFeeAdjusterCapOutOfRange(uint24 capBps);

    Opcode constant opcode = Opcode.BaseFeeAdjusterBalanceOut;

    uint256 constant ONE = 1e18;
    uint256 constant BPS = 1e7;

    function build(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) internal pure returns (bytes memory) {
        require(capBps < BPS, BaseFeeAdjusterCapOutOfRange(capBps));

        bytes memory args = abi.encodePacked(baseGasPrice, ethPrice, gasAmount, capBps);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) {
        baseGasPrice = args.at(0).asU64();
        ethPrice = args.at(8).asU96();
        gasAmount = args.at(20).asU24();
        capBps = args.at(23).asU24();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) = parse(args);

        if (block.basefee <= baseGasPrice) return;

        uint256 tokenOutPremium = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        uint256 maxTokenOutPremium = ctx.swap.balanceOut * capBps / (BPS - capBps);
        if (tokenOutPremium > maxTokenOutPremium) tokenOutPremium = maxTokenOutPremium;

        ctx.swap.balanceOut += tokenOutPremium;
    }
}
