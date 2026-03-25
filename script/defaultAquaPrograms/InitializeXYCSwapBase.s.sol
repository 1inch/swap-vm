// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Fee } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

import { AquaInitBase } from "./AquaInitBase.s.sol";

/// @title InitializeXYCSwapBase
/// @notice Shared logic for vanilla XYC (constant product) strategy initialization scripts.
abstract contract InitializeXYCSwapBase is AquaInitBase {
    using ProgramBuilder for Program;

    function _initialize(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        uint32 feeBps,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal {
        require(balA > 0 && balB > 0, "Both balances must be > 0");

        bytes memory bytecode = _buildDefaultAquaProgram(feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        console2.log("=== XYC Constant Product Strategy ===");
        _logCommonParams(feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);

        (bytes32 strategyHash,) = _shipStrategy(aqua, router, tokenA, tokenB, balA, balB, bytecode);

        string memory extra = "xycSwap";
        vm.serializeUint(extra, "feeBps", uint256(feeBps));
        vm.serializeUint(extra, "protocolFeeBps", uint256(protocolFeeBps));
        vm.serializeAddress(extra, "protocolFeeRecipient", protocolFeeRecipient);
        string memory extraJson = vm.serializeAddress(extra, "kycNft", kycNft);

        _saveDeployment(strategyHash, router, aqua, tokenA, tokenB, balA, balB, extraJson);
    }

    function _buildDefaultAquaProgram(
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
            program.build(XYCSwap._xycSwapXD)
        );
    }
}
// solhint-enable no-console
