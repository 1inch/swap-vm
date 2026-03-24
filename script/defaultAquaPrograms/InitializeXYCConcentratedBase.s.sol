// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../../src/instructions/XYCConcentrate.sol";
import { Fee } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

import { AquaInitBase } from "./AquaInitBase.s.sol";

/// @title InitializeXYCConcentratedBase
/// @notice Shared logic for XYC Concentrated Liquidity strategy initialization scripts.
abstract contract InitializeXYCConcentratedBase is AquaInitBase {
    using ProgramBuilder for Program;

    function _initialize(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal {
        require(sqrtPriceMin < sqrtPriceMax, "sqrtPriceMin must be < sqrtPriceMax");

        bytes memory bytecode = _buildDefaultAquaProgram(sqrtPriceMin, sqrtPriceMax, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        console2.log("=== XYC Concentrated Liquidity Strategy ===");
        console2.log("sqrtPriceMin: ", sqrtPriceMin);
        console2.log("sqrtPriceMax: ", sqrtPriceMax);
        _logCommonParams(feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        bytes32 strategyHash = _shipStrategy(aqua, router, tokenA, tokenB, balA, balB, bytecode);

        string memory extra = "xycConcentrated";
        vm.serializeUint(extra, "sqrtPriceMin", sqrtPriceMin);
        vm.serializeUint(extra, "sqrtPriceMax", sqrtPriceMax);
        vm.serializeUint(extra, "feeBps", uint256(feeBps));
        vm.serializeUint(extra, "protocolFeeBps", uint256(protocolFeeBps));
        vm.serializeAddress(extra, "protocolFeeRecipient", protocolFeeRecipient);
        string memory extraJson = vm.serializeAddress(extra, "kycNft", kycNft);

        _saveDeployment(strategyHash, router, aqua, tokenA, tokenB, balA, balB, extraJson);
    }

    function _buildDefaultAquaProgram(
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal pure returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            _buildPrefix(program, protocolFeeBps, protocolFeeRecipient, kycNft),
            program.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPriceMin, sqrtPriceMax)
            ),
            program.build(
                Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)
            ),
            program.build(XYCSwap._xycSwapXD)
        );
    }
}
// solhint-enable no-console
