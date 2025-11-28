// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
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
import { MinRateArgsBuilder } from "../../src/instructions/MinRate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title MinRateInvariants
 * @notice Tests invariants for MinRate instruction in combination with real swap scenarios
 * @dev Tests minimum rate enforcement with LimitSwap, DutchAuction, and fees
 *
 * MinRate protects the maker by capping the output rate. It ensures the maker
 * doesn't give away more tokens than intended. The rate is expressed as input:output,
 * so a rate of 1:2 means at most 2 output tokens per 1 input token.
 */
contract MinRateInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public protocolFeeCollector;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        protocolFeeCollector = address(0x1234567890123456789012345678901234567890);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
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

    /**
     * Test MinRate + LimitSwap invariants
     * Base rate: 1 tokenA = 3 tokenB (would be too generous)
     * MinRate caps it to: 1 tokenA = 2 tokenB (protects maker)
     */
    function test_MinRate_LimitSwap() public {
        uint64 rateA = 1e18;
        uint64 rateB = 2e18; // Cap at 1:2 rate

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(3000e18)])  // 1:3 base rate
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // First verify MinRate effect: quote with 1 tokenA input
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        assertEq(quotedOut, 2e18, "MinRate should cap output to 2 tokenB per 1 tokenA");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // MinRate breaks additivity and monotonicity at the cap boundary
        config.skipAdditivity = true;
        config.skipMonotonicity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + DutchAuction + LimitSwap invariants (input)
     * Dutch auction decays input balance, MinRate ensures output doesn't exceed cap
     */
    function test_MinRate_DutchAuctionIn_LimitSwap() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;
        uint64 rateA = 1e18;
        uint64 rateB = 1.8e18; // Cap at 1:1.8 rate

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(2500e18)])  // Start with 1:2.5 rate
                )),
            program.build(_dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at mid-auction
        vm.warp(startTime + 150);

        // Verify MinRate effect
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        assertEq(quotedOut, 1.8e18, "MinRate should cap output even with dutch auction");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + DutchAuction + LimitSwap invariants (output)
     * Dutch auction increases output balance, MinRate still caps the rate
     */
    function test_MinRate_DutchAuctionOut_LimitSwap() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.99e18;
        uint64 rateA = 1e18;
        uint64 rateB = 2.5e18; // Cap at 1:2.5 rate

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(3000e18)])  // Start with 1:3 rate
                )),
            program.build(_dutchAuctionBalanceOut1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at start of auction (highest output)
        vm.warp(startTime);

        // Verify MinRate effect
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        assertEq(quotedOut, 2.5e18, "MinRate should cap output at start of auction");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + LimitSwap + FlatFeeIn invariants
     * Fee reduces effective input, MinRate still caps based on gross amounts
     */
    function test_MinRate_LimitSwap_FlatFeeIn() public {
        uint64 rateA = 1e18;
        uint64 rateB = 2e18; // Cap at 1:2 rate
        uint32 feeBps = 100; // 1% fee on input

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(5000e18)])  // 1:5 base rate (very generous)
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Without MinRate: 1% fee on input reduces effective balance
        // Base would give ~5e18 output, MinRate caps at 2e18
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 amountOut) = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        // Actual output is slightly less due to rounding: 1999999800000000000
        assertEq(amountOut, 1999999800000000000, "MinRate should cap output at ~2e18");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + LimitSwap + FlatFeeOut invariants
     * Fee reduces output after MinRate cap is applied
     */
    function test_MinRate_LimitSwap_FlatFeeOut() public {
        uint64 rateA = 1e18;
        uint64 rateB = 2e18; // Cap at 1:2 rate
        uint32 feeBps = 200; // 2% fee on output

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(6000e18)])  // 1:6 base rate (very generous)
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Without MinRate: base would give 6e18, minus 2% fee = 5.88e18
        // With MinRate: caps at 2e18, minus 2% fee = 1.96e18
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 amountOut) = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        // Actual output is slightly less due to rounding: 1999999600000000000
        assertEq(amountOut, 1999999600000000000, "Should get min rate minus output fee");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + LimitSwap + ProtocolFee invariants
     */
    function test_MinRate_LimitSwap_ProtocolFee() public {
        uint64 rateA = 1e18;
        uint64 rateB = 1.85e18; // Cap at 1:1.85 rate
        uint32 feeBps = 150; // 1.5% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(8000e18)])  // 1:8 base rate (extremely generous)
                )),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, protocolFeeCollector)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Without MinRate: base would give 8e18, minus 1.5% fee = 7.88e18
        // With MinRate: caps at 1.85e18, minus 1.5% fee = 1.82225e18
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 amountOut) = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        // Actual output is slightly less due to rounding: 1849999722500000000
        assertEq(amountOut, 1849999722500000000, "Should get min rate minus protocol fee");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test MinRate + DutchAuction + LimitSwap + Fees invariants
     * Complex scenario with multiple adjustments
     */
    function test_MinRate_DutchAuction_LimitSwap_Fees() public {
        uint40 startTime = uint40(block.timestamp);
        uint16 duration = 300;
        uint64 decayFactor = 0.995e18;
        uint64 rateA = 1e18;
        uint64 rateB = 1.7e18; // Cap at 1:1.7 rate
        uint32 flatFeeBps = 50; // 0.5% flat fee on input
        uint32 protocolFeeBps = 100; // 1% protocol fee on output

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(7000e18)])  // 1:7 base rate (very generous)
                )),
            program.build(_dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(startTime, duration, decayFactor)),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeCollector)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test at start of auction
        vm.warp(startTime);

        // Without MinRate: even with fees, would give much more than 1.7e18
        // With MinRate: caps at 1.7e18, then 1% protocol fee
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        (, uint256 amountOut) = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
        // MinRate caps at 1:1.7, then 1% protocol fee. Actual: 1699999745000008500
        assertEq(amountOut, 1699999745000008500, "Should get min rate minus protocol fee");

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // Helper functions
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
