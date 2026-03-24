// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { PeggedSwapArgsBuilder } from "../../src/instructions/PeggedSwap.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { PeggedSwap } from "../../src/instructions/PeggedSwap.sol";
import { Fee } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

import { AquaInitBase } from "./AquaInitBase.s.sol";

/// @title InitializePeggedSwapBase
/// @notice Shared logic for PeggedSwap strategy initialization scripts.
abstract contract InitializePeggedSwapBase is AquaInitBase {
    using ProgramBuilder for Program;

    function _initialize(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateLt,
        uint256 rateGt,
        uint32 feeBps,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal {
        bytes memory bytecode = _buildDefaultAquaProgram(x0, y0, linearWidth, rateLt, rateGt, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        console2.log("=== PeggedSwap Strategy ===");
        console2.log("x0:           ", x0);
        console2.log("y0:           ", y0);
        console2.log("linearWidth:  ", linearWidth);
        console2.log("rateLt:       ", rateLt);
        console2.log("rateGt:       ", rateGt);
        _logCommonParams(feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        bytes32 strategyHash = _shipStrategy(aqua, router, tokenA, tokenB, balA, balB, bytecode);

        string memory extra = "peggedSwap";
        vm.serializeUint(extra, "x0", x0);
        vm.serializeUint(extra, "y0", y0);
        vm.serializeUint(extra, "linearWidth", linearWidth);
        vm.serializeUint(extra, "rateLt", rateLt);
        vm.serializeUint(extra, "rateGt", rateGt);
        vm.serializeUint(extra, "feeBps", uint256(feeBps));
        vm.serializeUint(extra, "protocolFeeBps", uint256(protocolFeeBps));
        vm.serializeAddress(extra, "protocolFeeRecipient", protocolFeeRecipient);
        string memory extraJson = vm.serializeAddress(extra, "kycNft", kycNft);

        _saveDeployment(strategyHash, router, aqua, tokenA, tokenB, balA, balB, extraJson);
    }

    function _buildDefaultAquaProgram(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateLt,
        uint256 rateGt,
        uint32 feeBps,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal pure returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            _buildPrefix(program, protocolFeeBps, protocolFeeRecipient, kycNft),
            program.build(
                Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)
            ),
            program.build(
                PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0,
                    y0: y0,
                    linearWidth: linearWidth,
                    rateLt: rateLt,
                    rateGt: rateGt
                }))
            )
        );
    }
}
// solhint-enable no-console
