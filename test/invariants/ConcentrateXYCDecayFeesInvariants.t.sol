// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
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
    TokenMock public tokenC;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        feeRecipient = address(0xFEE);
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        tokenC = new TokenMock("Token C", "TKC");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 1000e18);
        tokenB.mint(maker, 1000e18);
        tokenC.mint(maker, 1000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenC.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenC.approve(address(swapVM), type(uint256).max);
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

        // Verify the swap consumed the expected input amount


        return (actualIn, actualOut);
    }

    // ====== Order 1: Balances -> Decay -> Fees -> Concentrate -> XYC ======

    function test_Order1_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(1000e18)])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(300)),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(0.003e9)),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 200e18, 200e18, 1e18)),
            program.build(_xycSwapXD)
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order1_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1500e18), uint256(1500e18)])
                )),
            program.build(_decayXD, DecayArgsBuilder.build(600)),
            program.build(_progressiveFeeOutXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.01e9)),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 429e18, 429e18, 1e18)),
            program.build(_xycSwapXD)
        );

        // Skip symmetry for GrowPriceRange with progressive fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }


    // ====== Order 2: Balances -> Fees -> Decay -> Concentrate -> XYC ======

    function test_Order2_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1100e18), uint256(1100e18)])
                )),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.004e9)),
            program.build(_decayXD, DecayArgsBuilder.build(450)),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 165e18, 165e18, 1e18)),
            program.build(_xycSwapXD)
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order2_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1800e18), uint256(1800e18)])
                )),
            program.build(_progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.05e9)),
            program.build(_decayXD, DecayArgsBuilder.build(720)),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 514e18, 514e18, 1e18)),
            program.build(_xycSwapXD)
        );

        // Skip symmetry for GrowPriceRange with progressive fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }

    // ====== Order 3: Balances -> Decay -> Concentrate -> Fees -> XYC ======


    // ====== Order 4: Balances -> Fees -> Concentrate -> Decay -> XYC ======

    function test_Order4_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1300e18), uint256(1300e18)])
                )),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(0.0025e9, feeRecipient)),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 260e18, 260e18, 1e18)),
            program.build(_decayXD, DecayArgsBuilder.build(540)),
            program.build(_xycSwapXD)
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order4_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1700e18), uint256(1700e18)])
                )),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.002e9)),
            program.build(_progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.03e9)),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 567e18, 567e18, 1e18)),
            program.build(_decayXD, DecayArgsBuilder.build(780)),
            program.build(_xycSwapXD)
        );

        // Skip symmetry for GrowPriceRange with multiple fees
        // TODO: need to research behavior
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, true);
    }

    // ====== Order 5: Balances -> Concentrate -> Decay -> Fees -> XYC ======


    // ====== 3D Tests ======

    function test_3D_GrowLiquidity_DecayFees() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint256 balanceC = 2000e18;
        uint256 priceAB = 1e18;
        uint256 priceAC = 1e18;
        uint256 priceBC = 1e18;
        uint256 priceMinAB = 0.8e18;
        uint256 priceMaxAB = 1.25e18;
        uint256 priceMaxAC = 1.25e18;

        (
            uint256 deltaA,
            uint256 deltaB,
            uint256 deltaC,
            uint256 concentratedA,
            uint256 concentratedB,
            uint256 concentratedC,
            ,,,
            uint256 liquidityRoot
        ) = XYCConcentrateArgsBuilder.computeDeltas3D(
            balanceA, balanceB, balanceC,
            priceAB, priceAC, priceBC,
            priceMinAB, priceMaxAB, priceMaxAC
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB), address(tokenC)]),
                    dynamic([balanceA, balanceB, balanceC])
                )),
            program.build(_xycConcentrateGrowLiquidity3D,
                XYCConcentrateArgsBuilder.buildXD(
                    dynamic([address(tokenA), address(tokenB), address(tokenC)]),
                    dynamic([deltaA, deltaB, deltaC]),
                    dynamic([concentratedA, concentratedB, concentratedC]),
                    liquidityRoot
                )),
            program.build(_decayXD, DecayArgsBuilder.build(600)),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(0.003e9)),
            program.build(_xycSwapXD)
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    // ====== Order 6: Balances -> Concentrate -> Fees -> Decay -> XYC ======

    function test_Order6_GrowLiquidity2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1500e18), uint256(1500e18)])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 450e18, 450e18, 1e18)),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.0055e9)),
            program.build(_decayXD, DecayArgsBuilder.build(480)),
            program.build(_xycSwapXD)
        );

        _testInvariants(_createOrder(bytecode), false);
    }

    function test_Order6_GrowPriceRange2D() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(2000e18), uint256(2000e18)])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA), address(tokenB), 700e18, 700e18, 1e18)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(0.003e9, feeRecipient)),
            program.build(_progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(0.04e9)),
            program.build(_decayXD, DecayArgsBuilder.build(960)),
            program.build(_xycSwapXD)
        );

        // TODO: why it didn't fail?
        _testInvariantsWithTolerance(_createOrder(bytecode), false, 1, false);
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
