// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { DecayArgsBuilder } from "../../src/instructions/Decay.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { FeeArgsBuilderExperimental } from "../../src/instructions/FeeExperimental.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title ConcentrateXYCDecayFeesInvariants
 * @notice Tests invariants for all combinations of Concentrate + XYC + Decay + Fees
 * @dev Tests all possible orderings ensuring concentrate always comes before XYC
 */
contract ConcentrateXYCDecayFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        feeRecipient = address(0xFEE);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 1000e18);
        tokenB.mint(maker, 1000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _concentrateBalances(
        uint256 available,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (uint256 balA, uint256 balB) {
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
                available, available, 1e18, sqrtPmin, sqrtPmax
            );
        (balA, balB) = address(tokenA) < address(tokenB)
            ? (actualLt, actualGt)
            : (actualGt, actualLt);
    }

    /**
     * @notice Implementation of _executeSwap for real swap execution
     */
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount * 10);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        return (actualIn, actualOut);
    }

    /// @dev Returns correct initial balances for the standard concentrate range [0.8, 1.25].
    function _cBalances(uint256 available) internal view returns (uint256[2] memory) {
        (uint256 bA, uint256 bB) = _concentrateBalances(available, _sqrtPmin(), _sqrtPmax());
        return [bA, bB];
    }

    function _sqrtPmin() internal pure returns (uint256) { return Math.sqrt(0.8e36); }
    function _sqrtPmax() internal pure returns (uint256) { return Math.sqrt(1.25e36); }
    function _cArgs() internal pure returns (bytes memory) {
        return XYCConcentrateArgsBuilder.build2D(_sqrtPmin(), _sqrtPmax());
    }

    // ====== Order 1: Balances -> Decay -> Concentrate -> Fees -> XYC ======

    function test_Order1_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1000e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(300)),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(0.003e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order1_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1500e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(600)),
            program.build(_progressiveFeeOutXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.01e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        // Skip symmetry for GrowPriceRange with progressive fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }

    // ====== Order 2: Balances -> Decay -> Concentrate -> Fees -> XYC ======

    function test_Order2_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1100e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(450)),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.004e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order2_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1800e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(720)),
            program.build(_progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.05e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        // Skip symmetry for GrowPriceRange with progressive fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }

    // ====== Order 3: Balances -> Decay -> Concentrate -> Fees -> XYC ======

    // ====== Order 4: Balances -> Decay -> Concentrate -> Fees -> XYC ======

    function test_Order4_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1300e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(540)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(0.0025e9, feeRecipient)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order4_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1700e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(780)),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.002e9)),
            program.build(_progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.03e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        // Skip symmetry for GrowPriceRange with multiple fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }

    function test_Order5_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        (uint256 _balA, uint256 _balB) = _concentrateBalances(1500e18, _sqrtPmin(), _sqrtPmax());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([_balA, _balB])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(480)),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.0055e9)),
            program.build(_xycConcentrateGrowLiquidity2D, _cArgs())
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    // ====== Helper Functions ======

    function _testInvariants(ISwapVM.Order memory order, bool skipAdditivity) private {
        _testInvariantsWithTolerance(order, skipAdditivity, 1, false);
    }

    function _testInvariantsWithTolerance(
        ISwapVM.Order memory order,
        bool skipAdditivity,
        uint256 tolerance,
        bool skipSymmetry
    ) private {
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]),
            tolerance
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        config.skipAdditivity = skipAdditivity || true; // Always skip for decay (state-dependent)
        // TODO: need to research behavior
        config.skipSymmetry = skipSymmetry;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: address(this),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }
}
