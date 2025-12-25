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
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { DutchAuctionArgsBuilder } from "../../src/instructions/DutchAuction.sol";
import { TWAPSwap, TWAPSwapArgsBuilder } from "../../src/instructions/TWAPSwap.sol";
import { BaseFeeAdjusterArgsBuilder } from "../../src/instructions/BaseFeeAdjuster.sol";
import { MinRateArgsBuilder } from "../../src/instructions/MinRate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { ControlsArgsBuilder } from "../../src/instructions/Controls.sol";
import { InvalidatorsArgsBuilder } from "../../src/instructions/Invalidators.sol";
import { dynamic } from "../utils/Dynamic.sol";

/**
 * @title LimitSwapGas
 * @notice Gas benchmarks for LimitSwap-based programs (staticBalances)
 * @dev Measures gas for quote and swap operations with various instruction combinations
 */
contract LimitSwapGas is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 2000e18;
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

    // ==================== LimitSwap ====================

    function test_gas_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapOrder(true);

        vm.startSnapshotGas("LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapOrder(false);

        vm.startSnapshotGas("LimitSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapOrder(true);

        vm.startSnapshotGas("LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapOrder(false);

        vm.startSnapshotGas("LimitSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== DutchAuction + LimitSwap ====================

    function test_gas_DutchAuctionIn_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(true, true);

        vm.startSnapshotGas("DutchAuctionIn_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionIn_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(true, false);

        vm.startSnapshotGas("DutchAuctionIn_LimitSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionIn_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(true, true);

        vm.startSnapshotGas("DutchAuctionIn_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionIn_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(true, false);

        vm.startSnapshotGas("DutchAuctionIn_LimitSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionOut_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(false, true);

        vm.startSnapshotGas("DutchAuctionOut_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionOut_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(false, false);

        vm.startSnapshotGas("DutchAuctionOut_LimitSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionOut_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(false, true);

        vm.startSnapshotGas("DutchAuctionOut_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_DutchAuctionOut_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDutchAuctionOrder(false, false);

        vm.startSnapshotGas("DutchAuctionOut_LimitSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== TWAP + LimitSwap ====================

    function test_gas_TWAP_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _createTWAPOrder(true);
        vm.warp(startTime + 1800); // 50% of duration unlocked

        vm.startSnapshotGas("TWAP_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_TWAP_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _createTWAPOrder(false);
        vm.warp(startTime + 1800); // 50% of duration unlocked

        vm.startSnapshotGas("TWAP_LimitSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_TWAP_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _createTWAPOrder(true);
        vm.warp(startTime + 1800); // 50% of duration unlocked

        vm.startSnapshotGas("TWAP_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_TWAP_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _createTWAPOrder(false);
        vm.warp(startTime + 1800); // 50% of duration unlocked

        vm.startSnapshotGas("TWAP_LimitSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== MinRate + LimitSwap ====================

    function test_gas_MinRate_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createMinRateOrder(true);

        vm.startSnapshotGas("MinRate_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_MinRate_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createMinRateOrder(false);

        vm.startSnapshotGas("MinRate_LimitSwap_quote_exactOut");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_MinRate_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createMinRateOrder(true);

        vm.startSnapshotGas("MinRate_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_MinRate_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createMinRateOrder(false);

        vm.startSnapshotGas("MinRate_LimitSwap_swap_exactOut");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== LimitSwap + FlatFeeIn ====================

    function test_gas_LimitSwap_FlatFeeIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(true, true, false);

        vm.startSnapshotGas("LimitSwap_FlatFeeIn_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_FlatFeeIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(true, true, false);

        vm.startSnapshotGas("LimitSwap_FlatFeeIn_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== LimitSwap + FlatFeeOut ====================

    function test_gas_LimitSwap_FlatFeeOut_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(false, true, false);

        vm.startSnapshotGas("LimitSwap_FlatFeeOut_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_FlatFeeOut_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(false, true, false);

        vm.startSnapshotGas("LimitSwap_FlatFeeOut_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== LimitSwap + ProgressiveFee ====================

    function test_gas_LimitSwap_ProgressiveFee_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(true, true, true);

        vm.startSnapshotGas("LimitSwap_ProgressiveFee_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_ProgressiveFee_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapWithFeeOrder(true, true, true);

        vm.startSnapshotGas("LimitSwap_ProgressiveFee_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Deadline + LimitSwap ====================

    function test_gas_Deadline_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDeadlineLimitSwapOrder(true);

        vm.startSnapshotGas("Deadline_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Deadline_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createDeadlineLimitSwapOrder(true);

        vm.startSnapshotGas("Deadline_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Salt + LimitSwap ====================

    function test_gas_Salt_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createSaltLimitSwapOrder(true);

        vm.startSnapshotGas("Salt_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_Salt_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createSaltLimitSwapOrder(true);

        vm.startSnapshotGas("Salt_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== InvalidateBit + LimitSwap ====================

    function test_gas_InvalidateBit_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createInvalidateBitLimitSwapOrder(true);

        vm.startSnapshotGas("InvalidateBit_LimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_InvalidateBit_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createInvalidateBitLimitSwapOrder(true);

        vm.startSnapshotGas("InvalidateBit_LimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== LimitSwap + InvalidateTokenIn ====================

    function test_gas_LimitSwap_InvalidateTokenIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapInvalidateTokenInOrder(true);

        vm.startSnapshotGas("LimitSwap_InvalidateTokenIn_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_LimitSwap_InvalidateTokenIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createLimitSwapInvalidateTokenInOrder(true);

        vm.startSnapshotGas("LimitSwap_InvalidateTokenIn_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Full LimitSwap Stack ====================

    function test_gas_FullLimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createFullLimitSwapOrder(true);

        vm.startSnapshotGas("FullLimitSwap_quote_exactIn");
        swapVM.asView().quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    function test_gas_FullLimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _createFullLimitSwapOrder(true);

        vm.startSnapshotGas("FullLimitSwap_swap_exactIn");
        swapVM.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        vm.stopSnapshotGas();
    }

    // ==================== Helper Functions ====================

    function _createLimitSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createDutchAuctionOrder(bool isAuctionIn, bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.5e18; // 50% decay

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            isAuctionIn ?
                program.build(_dutchAuctionBalanceIn1D,
                    DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)) :
                program.build(_dutchAuctionBalanceOut1D,
                    DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createTWAPOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory, uint256) {
        uint256 startTime = block.timestamp;
        uint256 duration = 3600; // 1 hour
        uint256 balanceOut = BALANCE_B;
        uint256 balanceIn = BALANCE_A;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_twap,
                TWAPSwapArgsBuilder.build(TWAPSwapArgsBuilder.TwapArgs({
                    balanceIn: balanceIn,
                    balanceOut: balanceOut,
                    startTime: startTime,
                    duration: duration,
                    priceBumpAfterIlliquidity: 1.2e18,
                    minTradeAmountOut: 0.1e18
                }))),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData, startTime);
    }

    function _createMinRateOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint64 rateA = 1e8; // 1 tokenA
        uint64 rateB = 1.5e8; // 1.5 tokenB per tokenA

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createLimitSwapWithFeeOrder(bool isFeeIn, bool isExactIn, bool isProgressive) private view returns (ISwapVM.Order memory, bytes memory) {
        uint32 feeBps = 100; // 1%

        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory feeInstruction;
        if (isProgressive) {
            feeInstruction = program.build(_progressiveFeeInXD, FeeArgsBuilder.buildProgressiveFee(feeBps));
        } else if (isFeeIn) {
            feeInstruction = program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps));
        } else {
            feeInstruction = program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(feeBps));
        }

        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            feeInstruction,
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
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

    function _createDeadlineLimitSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint40 deadline = uint40(block.timestamp + 3600); // 1 hour from now

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_deadline,
                ControlsArgsBuilder.buildDeadline(deadline)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createSaltLimitSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint64 salt = 12345678;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_salt,
                ControlsArgsBuilder.buildSalt(salt)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createInvalidateBitLimitSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint32 bitIndex = 42;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_invalidateBit1D,
                InvalidatorsArgsBuilder.buildInvalidateBit(bitIndex)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createLimitSwapInvalidateTokenInOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_invalidateTokenIn1D)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }

    function _createFullLimitSwapOrder(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint40 deadline = uint40(block.timestamp + 3600);
        uint64 salt = 99999;
        uint32 feeBps = 30; // 0.3%

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_deadline,
                ControlsArgsBuilder.buildDeadline(deadline)),
            program.build(_salt,
                ControlsArgsBuilder.buildSalt(salt)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE_A, BALANCE_B])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            program.build(_invalidateTokenIn1D)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);

        return (order, takerData);
    }
}
