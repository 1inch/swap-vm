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
import { dynamic } from "../utils/Dynamic.sol";

/**
 * @title AMMGas
 * @notice Gas benchmarks for AMM-based programs (dynamicBalances + XYCSwap)
 * @dev Measures gas for quote and swap operations with XYC, Concentrate, and Decay
 */
contract AMMGas is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 1000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.mint(taker, 1e30);
        tokenB.mint(taker, 1e30);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ==================== XYCSwap (Basic AMM) ====================

    function test_gas_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapOrder(true);

        vm.startSnapshotGas("XYCSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapOrder(false);

        vm.startSnapshotGas("XYCSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapOrder(true);

        vm.startSnapshotGas("XYCSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapOrder(false);

        vm.startSnapshotGas("XYCSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== XYCConcentrate + XYCSwap ====================

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowLiquidityOrder(true);

        vm.startSnapshotGas("ConcentrateGrowLiquidity_XYCSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowLiquidityOrder(false);

        vm.startSnapshotGas("ConcentrateGrowLiquidity_XYCSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowLiquidityOrder(true);

        vm.startSnapshotGas("ConcentrateGrowLiquidity_XYCSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowLiquidityOrder(false);

        vm.startSnapshotGas("ConcentrateGrowLiquidity_XYCSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowPriceRangeOrder(true);

        vm.startSnapshotGas("ConcentrateGrowPriceRange_XYCSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateGrowPriceRangeOrder(true);

        vm.startSnapshotGas("ConcentrateGrowPriceRange_XYCSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Decay + XYCSwap ====================

    function test_gas_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDecayXYCSwapOrder(true);

        vm.startSnapshotGas("Decay_XYCSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Decay_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDecayXYCSwapOrder(false);

        vm.startSnapshotGas("Decay_XYCSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDecayXYCSwapOrder(true);

        vm.startSnapshotGas("Decay_XYCSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Decay_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDecayXYCSwapOrder(false);

        vm.startSnapshotGas("Decay_XYCSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== XYCConcentrate + Decay + XYCSwap ====================

    function test_gas_Concentrate_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateDecayXYCSwapOrder(true);

        vm.startSnapshotGas("Concentrate_Decay_XYCSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Concentrate_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createConcentrateDecayXYCSwapOrder(true);

        vm.startSnapshotGas("Concentrate_Decay_XYCSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== XYCSwap + Fees ====================

    function test_gas_XYCSwap_FlatFeeIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapWithFeeOrder(true, true);

        vm.startSnapshotGas("XYCSwap_FlatFeeIn_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_FlatFeeIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapWithFeeOrder(true, true);

        vm.startSnapshotGas("XYCSwap_FlatFeeIn_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_FlatFeeOut_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapWithFeeOrder(false, true);

        vm.startSnapshotGas("XYCSwap_FlatFeeOut_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_XYCSwap_FlatFeeOut_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createXYCSwapWithFeeOrder(false, true);

        vm.startSnapshotGas("XYCSwap_FlatFeeOut_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Full AMM Stack (Concentrate + Decay + Fee + XYCSwap) ====================

    function test_gas_FullAMM_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createFullAMMOrder(true);

        vm.startSnapshotGas("FullAMM_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_FullAMM_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createFullAMMOrder(true);

        vm.startSnapshotGas("FullAMM_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Helper Functions ====================

    function _createXYCSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createConcentrateGrowLiquidityOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            BALANCE_A,
            BALANCE_B,
            currentPrice,
            priceMin,
            priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createConcentrateGrowPriceRangeOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.7e18;
        uint256 priceMax = 1.4e18;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            BALANCE_A,
            BALANCE_B,
            currentPrice,
            priceMin,
            priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createDecayXYCSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint16 decayPeriod = 3600; // 1 hour decay period

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createConcentrateDecayXYCSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            BALANCE_A,
            BALANCE_B,
            currentPrice,
            priceMin,
            priceMax
        );

        uint16 decayPeriod = 3600;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createXYCSwapWithFeeOrder(bool isFeeIn, bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint32 feeBps = 100; // 1%

        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory feeInstruction = isFeeIn ?
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)) :
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(feeBps));

        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            feeInstruction,
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createFullAMMOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            BALANCE_A,
            BALANCE_B,
            currentPrice,
            priceMin,
            priceMax
        );

        uint16 decayPeriod = 3600;
        uint32 feeBps = 30; // 0.3%

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
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
