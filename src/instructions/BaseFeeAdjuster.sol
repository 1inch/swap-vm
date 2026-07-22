// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";
import { InstructionArgs } from "../libs/InstructionArgs.sol";

/// @notice BaseFeeAdjuster opcode, price adjustment based on network gas costs with price percent cap
/// @dev Encoding: [uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint64 maxDecay]
/// @dev Supports only single direction swaps, eth price specified in token in
library BaseFeeAdjuster {
    using InstructionArgs for bytes;
    using InstructionArgs for bytes32;

    using Math for uint256;

    error BaseFeeAdjusterInvalidMaxDecay(uint256 linearWidth);

    Opcode constant opcode = Opcode.BaseFeeAdjuster;

    uint256 constant ONE = 1e18;

    function build(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint64 maxDecay) internal pure returns (bytes memory) {
        require(maxDecay < ONE, BaseFeeAdjusterInvalidMaxDecay(maxDecay));

        bytes memory args = abi.encodePacked(baseGasPrice, ethPrice, gasAmount, maxDecay);
        return InstructionBuilder.build(opcode, args);
    }

    function parse(bytes calldata args) internal pure returns (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint64 maxDecay) {
        baseGasPrice = args.at(0).asU64();
        ethPrice = args.at(8).asU96();
        gasAmount = args.at(20).asU24();
        maxDecay = args.at(23).asU64();
    }

    function exec(Context memory ctx, bytes calldata args) internal view {
        (uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint64 maxDecay) = parse(args);

        if (block.basefee <= baseGasPrice || ctx.swap.amountIn == 0) return;

        uint256 tokenInDiscount = (block.basefee - baseGasPrice) * gasAmount * ethPrice / ONE;
        uint256 maxTokenInDiscount = ctx.swap.amountIn * maxDecay / ONE;
        if (tokenInDiscount > maxTokenInDiscount) tokenInDiscount = maxTokenInDiscount;

        if (ctx.query.isExactIn) {
            ctx.swap.amountOut += tokenInDiscount * ctx.swap.amountOut / ctx.swap.amountIn;
        } else {
            ctx.swap.amountIn -= tokenInDiscount;
        }
    }
}
