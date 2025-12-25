// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { OpcodesDebug } from "../opcodes/OpcodesDebug.sol";
import { SwapVM, ISwapVM } from "../SwapVM.sol";
import { MakerTraitsLib } from "../libs/MakerTraits.sol";
import { ProgramBuilder, Program } from "../../test/utils/ProgramBuilder.sol";

import { DecayArgsBuilder } from "../instructions/Decay.sol";
import { XYCConcentrateArgsBuilder, ONE } from "../instructions/XYCConcentrate.sol";
import { FeeArgsBuilder, BPS } from "../instructions/Fee.sol";
import { ControlsArgsBuilder } from "../instructions/Controls.sol";

contract AquaAMM is OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    error ProtocolFeesExceedMakerFees(uint256 protocolFeeBps, uint256 makerFeeBps);

    constructor(address aqua) OpcodesDebug(aqua) {}

    function buildProgram(
        address maker,
        uint40 expiration,
        address token0,
        address token1,
        uint16 feeBpsIn,
        uint256 delta0,
        uint256 delta1,
        uint256 liquidity,
        uint16 decayPeriod,
        uint16 protocolFeeBpsIn,
        address feeReceiver,
        uint64 salt
    ) external pure returns (ISwapVM.Order memory) {
        require(protocolFeeBpsIn <= feeBpsIn, ProtocolFeesExceedMakerFees(protocolFeeBpsIn, feeBpsIn));

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            (delta0 != 0 || delta1 != 0) ? program.build(_xycConcentrateGrowLiquidity2D, XYCConcentrateArgsBuilder.build2D(token0, token1, delta0, delta1, liquidity)) : bytes(""),
            (decayPeriod > 0) ? program.build(_decayXD, DecayArgsBuilder.build(decayPeriod)) : bytes(""),
            (feeBpsIn > 0) ? program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBpsIn)) : bytes(""),
            (protocolFeeBpsIn > 0) ? program.build(_aquaProtocolFeeAmountOutXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBpsIn, feeReceiver)) : bytes(""),
            program.build(_xycSwapXD),
            program.build(_printContext),
            program.build(_deadline, ControlsArgsBuilder.buildDeadline(expiration)),
            (salt > 0) ? program.build(_salt, ControlsArgsBuilder.buildSalt(salt)) : bytes("")
        );

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: bytecode
        }));
    }
}
