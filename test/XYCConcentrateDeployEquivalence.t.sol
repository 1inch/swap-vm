// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { AquaOpcodes } from "../src/opcodes/AquaOpcodes.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../src/instructions/XYCConcentrate.sol";
import { Fee } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { XYCConcentratePriceSolver } from "../script/utils/XYCConcentratePriceSolver.sol";

/// @title XYCConcentrateDeployEquivalence
/// @notice Verifies that InitializeXYCConcentrated and InitializeXYCConcentratedFromBalances
///         produce identical strategies when given equivalent inputs.
contract XYCConcentrateDeployEquivalence is Test, AquaOpcodes {
    using ProgramBuilder for Program;
    using SafeCast for uint256;

    constructor() AquaOpcodes(address(1)) {}

    struct Params {
        uint256 amountLt;
        uint256 amountGt;
        uint256 sqrtPspot;
        uint256 sqrtPmin;
        uint256 sqrtPmax;
        uint32 feeBps;
    }

    function _buildProgram(uint256 sqrtPmin, uint256 sqrtPmax, uint32 feeBps) internal pure returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            program.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)
            ),
            program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(XYCSwap._xycSwapXD)
        );
    }

    function _buildOrder(
        address maker,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        uint32 feeBps
    ) internal pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            useAquaInsteadOfSignature: true,
            shouldUnwrapWeth: false,
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
            program: _buildProgram(sqrtPmin, sqrtPmax, feeBps)
        }));
    }

    /// @notice Script 1 path: amounts + both bounds → (bLt, bGt, order)
    function _script1(Params memory p) internal pure returns (uint256 bLt, uint256 bGt, bytes32 orderHash) {
        (, bLt, bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            p.amountLt, p.amountGt, p.sqrtPspot, p.sqrtPmin, p.sqrtPmax
        );
        ISwapVM.Order memory order = _buildOrder(address(0xBEEF), p.sqrtPmin, p.sqrtPmax, p.feeBps);
        orderHash = keccak256(abi.encode(order));
    }

    /// @notice Script 2 path: balances + sqrtPmin → derive sqrtPmax → order
    function _script2_fromMin(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint32 feeBps
    ) internal pure returns (uint256 derivedMax, bytes32 orderHash) {
        derivedMax = XYCConcentratePriceSolver.computeSqrtPriceMax(bLt, bGt, sqrtPspot, sqrtPmin);
        ISwapVM.Order memory order = _buildOrder(address(0xBEEF), sqrtPmin, derivedMax, feeBps);
        orderHash = keccak256(abi.encode(order));
    }

    /// @notice Script 2 path: balances + sqrtPmax → derive sqrtPmin → order
    function _script2_fromMax(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPspot,
        uint256 sqrtPmax,
        uint32 feeBps
    ) internal pure returns (uint256 derivedMin, bytes32 orderHash) {
        derivedMin = XYCConcentratePriceSolver.computeSqrtPriceMin(bLt, bGt, sqrtPspot, sqrtPmax);
        ISwapVM.Order memory order = _buildOrder(address(0xBEEF), derivedMin, sqrtPmax, feeBps);
        orderHash = keccak256(abi.encode(order));
    }

    // ======================== Tests ========================

    function test_DeriveMax_Symmetric() public pure {
        Params memory p = Params({
            amountLt: 1000e18,
            amountGt: 1000e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.8e36),
            sqrtPmax: Math.sqrt(1.25e36),
            feeBps: 0.003e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMax, bytes32 hash2) = _script2_fromMin(bLt, bGt, p.sqrtPspot, p.sqrtPmin, p.feeBps);

        assertApproxEqAbs(derivedMax, p.sqrtPmax, 2, "sqrtPmax should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMin_Symmetric() public pure {
        Params memory p = Params({
            amountLt: 1000e18,
            amountGt: 1000e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.8e36),
            sqrtPmax: Math.sqrt(1.25e36),
            feeBps: 0.003e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMin, bytes32 hash2) = _script2_fromMax(bLt, bGt, p.sqrtPspot, p.sqrtPmax, p.feeBps);

        assertApproxEqAbs(derivedMin, p.sqrtPmin, 2, "sqrtPmin should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMax_AsymmetricRange() public pure {
        Params memory p = Params({
            amountLt: 8000e18,
            amountGt: 9000e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.01e36),
            sqrtPmax: Math.sqrt(25e36),
            feeBps: 0.003e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMax, bytes32 hash2) = _script2_fromMin(bLt, bGt, p.sqrtPspot, p.sqrtPmin, p.feeBps);

        assertApproxEqAbs(derivedMax, p.sqrtPmax, 2, "sqrtPmax should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMin_AsymmetricRange() public pure {
        Params memory p = Params({
            amountLt: 8000e18,
            amountGt: 9000e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.01e36),
            sqrtPmax: Math.sqrt(25e36),
            feeBps: 0.003e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMin, bytes32 hash2) = _script2_fromMax(bLt, bGt, p.sqrtPspot, p.sqrtPmax, p.feeBps);

        assertApproxEqAbs(derivedMin, p.sqrtPmin, 2, "sqrtPmin should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMax_SpotNear1_NarrowRange() public pure {
        Params memory p = Params({
            amountLt: 500e18,
            amountGt: 500e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.99e36),
            sqrtPmax: Math.sqrt(1.01e36),
            feeBps: 0.001e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMax, bytes32 hash2) = _script2_fromMin(bLt, bGt, p.sqrtPspot, p.sqrtPmin, p.feeBps);

        assertApproxEqAbs(derivedMax, p.sqrtPmax, 2, "sqrtPmax should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMin_SpotNear1_NarrowRange() public pure {
        Params memory p = Params({
            amountLt: 500e18,
            amountGt: 500e18,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.99e36),
            sqrtPmax: Math.sqrt(1.01e36),
            feeBps: 0.001e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMin, bytes32 hash2) = _script2_fromMax(bLt, bGt, p.sqrtPspot, p.sqrtPmax, p.feeBps);

        assertApproxEqAbs(derivedMin, p.sqrtPmin, 2, "sqrtPmin should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }

    function test_DeriveMax_HighLiquidity() public pure {
        Params memory p = Params({
            amountLt: 2.5e25,
            amountGt: 2.5e25,
            sqrtPspot: 1e18,
            sqrtPmin: Math.sqrt(0.8e36),
            sqrtPmax: Math.sqrt(1.25e36),
            feeBps: 0.003e9
        });

        (uint256 bLt, uint256 bGt, bytes32 hash1) = _script1(p);
        (uint256 derivedMax, bytes32 hash2) = _script2_fromMin(bLt, bGt, p.sqrtPspot, p.sqrtPmin, p.feeBps);

        assertApproxEqAbs(derivedMax, p.sqrtPmax, 2, "sqrtPmax should match within 2 wei");
        assertEq(hash1, hash2, "Order hashes must be identical");
    }
}
