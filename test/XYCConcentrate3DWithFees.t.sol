// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/// @title 3D Concentrated Liquidity Tests with Fees
/// @notice Tests for _xycConcentrateGrowLiquidity3D with flat fee on amountIn
contract XYCConcentrate3DWithFeesTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    uint256 constant ONE = 1e18;
    uint256 constant FEE_BPS = 0.003e9; // 0.3% fee

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;
    address public tokenC;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));
        tokenC = address(new TokenMock("Token C", "TKC"));

        TokenMock(tokenA).mint(maker, 1_000_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000_000e18);
        TokenMock(tokenC).mint(maker, 1_000_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000_000e18);
        TokenMock(tokenC).mint(taker, 1_000_000_000e18);

        vm.startPrank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenC).approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenC).approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint256 balanceC;
        uint256 priceMin_AB;
        uint256 priceMax_AB;
        uint256 priceMax_AC;
        uint256 priceMin_AC;
        uint256 priceMin_BC;
        uint256 priceMax_BC;
    }

    function _createOrderWithFee(MakerSetup memory setup, uint256 price_AB, uint256 price_AC, uint256 price_BC) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        uint256 deltaA;
        uint256 deltaB;
        uint256 deltaC;
        uint256 concentratedA;
        uint256 concentratedB;
        uint256 concentratedC;
        uint256 liquidityRoot;
        (
            deltaA,
            deltaB,
            deltaC,
            concentratedA,
            concentratedB,
            concentratedC,
            setup.priceMin_AC,
            setup.priceMin_BC,
            setup.priceMax_BC,
            liquidityRoot
        ) = XYCConcentrateArgsBuilder.computeDeltas3D(
            setup.balanceA, setup.balanceB, setup.balanceC,
            price_AB, price_AC, price_BC,
            setup.priceMin_AB, setup.priceMax_AB, setup.priceMax_AC
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB), address(tokenC)]),
                    dynamic([setup.balanceA, setup.balanceB, setup.balanceC])
                )),
                program.build(XYCConcentrate._xycConcentrateGrowLiquidity3D, XYCConcentrateArgsBuilder.buildXD(
                    dynamic([address(tokenA), address(tokenB), address(tokenC)]),
                    dynamic([deltaA, deltaB, deltaC]),
                    dynamic([concentratedA, concentratedB, concentratedC]),
                    liquidityRoot
                )),
                // Add flat fee instruction
                program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(uint32(FEE_BPS))),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _quotingTakerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: false,  // exactOut
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function _swappingTakerData(bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: false,  // exactOut
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
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
    }

    /// @notice Helper to verify rate change with logging
    function _verifyRateChange(
        uint256 preAmountIn,
        uint256 preAmountOut,
        uint256 postAmountIn,
        uint256 postAmountOut,
        uint256 expectedRate,
        string memory label,
        bool isReverseDirection,
        uint256 tolerance
    ) internal {
        uint256 preRate = preAmountIn * ONE / preAmountOut;
        uint256 postRate = postAmountIn * ONE / postAmountOut;
        uint256 rateChange = isReverseDirection
            ? postRate * ONE / preRate
            : preRate * ONE / postRate;

        emit log_string(string(abi.encodePacked("\n--- Rate Change Analysis for ", label, " ---")));
        emit log_named_decimal_uint("preRate", preRate, 18);
        emit log_named_decimal_uint("postRate", postRate, 18);
        emit log_named_decimal_uint("rateChange", rateChange, 18);
        emit log_named_decimal_uint("expected", expectedRate, 18);

        assertApproxEqRel(rateChange, expectedRate, tolerance, string(abi.encodePacked("Rate change should match for ", label)));
    }

    function _printSetup(MakerSetup memory setup) internal {
        emit log_string("\n--- Maker Setup ---");
        emit log_named_decimal_uint("balanceA", setup.balanceA, 18);
        emit log_named_decimal_uint("balanceB", setup.balanceB, 18);
        emit log_named_decimal_uint("balanceC", setup.balanceC, 18);
        emit log_named_decimal_uint("priceMin_AB", setup.priceMin_AB, 18);
        emit log_named_decimal_uint("priceMax_AB", setup.priceMax_AB, 18);
        emit log_named_decimal_uint("priceMax_AC", setup.priceMax_AC, 18);
        emit log_named_decimal_uint("priceMin_AC", setup.priceMin_AC, 18);
        emit log_named_decimal_uint("priceMin_BC", setup.priceMin_BC, 18);
        emit log_named_decimal_uint("priceMax_BC", setup.priceMax_BC, 18);
        emit log_named_decimal_uint("feeBps", FEE_BPS, 9);
    }

    /// @notice Test full swap with 0.3% fee and absolute prices
    function test_FullSwap_WithFee_Absolute() public {
        emit log_string("=== Test: 3D Full Swap with 0.3% Fee (Absolute Prices) ===");

        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: ONE / 4,  // 0.25
            priceMax_AB: 4 * ONE,
            priceMax_AC: 6 * ONE,
            priceMin_AC: 0,
            priceMin_BC: 0,
            priceMax_BC: 0
        });

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFee(setup, ONE, ONE, ONE);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory quoteData = _quotingTakerData();
        bytes memory swapData = _swappingTakerData(signature);

        _printSetup(setup);

        vm.startPrank(taker);

        // ====== SWAP 1: B -> A (fully drain A) ======
        emit log_string("\n\n=== SWAP 1: B -> A (drain all A) ===");
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);

        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapData);

        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB, "Token A", false, 0.006e18);

        (uint256 preAmountInA_CA, uint256 preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");
        swapVM.swap(order, tokenA, tokenB, swapVM.balances(orderHash, tokenB), swapData);
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB, "Token B", true, 0.006e18);

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        swapVM.swap(order, tokenA, tokenC, swapVM.balances(orderHash, tokenC), swapData);
        (uint256 postAmountInC, uint256 postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC, "Token C", true, 0.006e18);

        // ====== SWAP 4: C -> A (fully drain A again) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A again) ===");
        swapVM.swap(order, tokenC, tokenA, swapVM.balances(orderHash, tokenA), swapData);
        (uint256 postAmountInA_CA, uint256 postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC, "Token A", false, 0.006e18);

        vm.stopPrank();
    }

    /// @notice Test full swap with 0.3% fee and current prices
    function test_FullSwap_WithFee_CurrentPrice() public {
        emit log_string("=== Test: 3D Full Swap with 0.3% Fee (Current Prices) ===");

        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: 0,
            priceMax_AB: 0,
            priceMax_AC: 0,
            priceMin_AC: 0,
            priceMin_BC: 0,
            priceMax_BC: 0
        });

        // Calculate current prices
        uint256 price_AB = setup.balanceB * ONE / setup.balanceA;  // 1.5
        uint256 price_AC = setup.balanceC * ONE / setup.balanceA;  // 2.0
        uint256 price_BC = setup.balanceC * ONE / setup.balanceB;  // 1.333...

        // Define relative ranges
        setup.priceMin_AB = price_AB / 4;  // 0.375
        setup.priceMax_AB = price_AB * 4;  // 6.0
        setup.priceMax_AC = price_AC * 6;  // 12.0

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFee(setup, price_AB, price_AC, price_BC);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory quoteData = _quotingTakerData();
        bytes memory swapData = _swappingTakerData(signature);

        _printSetup(setup);

        vm.startPrank(taker);

        // ====== SWAP 1: B -> A (fully drain A) ======
        emit log_string("\n\n=== SWAP 1: B -> A (drain all A) ===");
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);

        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapData);

        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB * ONE / price_AB, "Token A (relative)", false, 0.006e18);

        (uint256 preAmountInA_CA, uint256 preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");
        swapVM.swap(order, tokenA, tokenB, swapVM.balances(orderHash, tokenB), swapData);
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB * ONE / price_AB, "Token B (relative)", true, 0.006e18);

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        swapVM.swap(order, tokenA, tokenC, swapVM.balances(orderHash, tokenC), swapData);
        (uint256 postAmountInC, uint256 postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC * ONE / price_AC, "Token C (relative)", true, 0.006e18);

        // ====== SWAP 4: C -> A (fully drain A again) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A again) ===");
        swapVM.swap(order, tokenC, tokenA, swapVM.balances(orderHash, tokenA), swapData);
        (uint256 postAmountInA_CA, uint256 postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC * ONE / price_AC, "Token A (relative)", false, 0.006e18);

        vm.stopPrank();
    }

    /// @notice Test multiple swaps (100x each direction) with 0.3% fee and current prices
    function test_MultipleSwaps_WithFee_GrowLiquidity() public {
        emit log_string("=== Test: 3D Multiple Swaps (100x each) with 0.3% Fee ===");

        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: 0,
            priceMax_AB: 0,
            priceMax_AC: 0,
            priceMin_AC: 0,
            priceMin_BC: 0,
            priceMax_BC: 0
        });

        // Calculate current prices
        uint256 price_AB = setup.balanceB * ONE / setup.balanceA;  // 1.5
        uint256 price_AC = setup.balanceC * ONE / setup.balanceA;  // 2.0
        uint256 price_BC = setup.balanceC * ONE / setup.balanceB;  // 1.333...

        // Define relative ranges
        setup.priceMin_AB = price_AB / 4;  // 0.375
        setup.priceMax_AB = price_AB * 4;  // 6.0
        setup.priceMax_AC = price_AC * 6;  // 12.0

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFee(setup, price_AB, price_AC, price_BC);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory quoteData = _quotingTakerData();
        bytes memory swapData = _swappingTakerData(signature);

        _printSetup(setup);

        vm.startPrank(taker);

        // ====== SWAP PAIR 1: B <-> A (100 times) ======
        emit log_string("\n\n=== SWAP PAIR 1: B <-> A x 100 ===");
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        uint256 postAmountInA; uint256 postAmountOutA;
        uint256 postAmountInB; uint256 postAmountOutB;
        uint256 preAmountInA_CA; uint256 preAmountOutA_CA;

        (preAmountInA_CA, preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        for (uint256 i = 0; i < 100; i++) {
            // Buy all tokenA (B -> A)
            uint256 balanceTokenA = swapVM.balances(orderHash, tokenA);
            if (i == 0) {
                balanceTokenA = setup.balanceA; // First iteration doesn't have balances in state yet
            }
            swapVM.swap(order, tokenB, tokenA, balanceTokenA, swapData);
            (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);

            (preAmountInA_CA, preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

            // Buy all tokenB (A -> B)
            uint256 balanceTokenB = swapVM.balances(orderHash, tokenB);
            swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapData);
            (postAmountInB, postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        }

        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB * ONE / price_AB, "Token A (relative) after 100 swap pairs", false, 0.4e18);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB * ONE / price_AB, "Token B (relative) after 100 swap pairs", true, 0.4e18);

        // ====== SWAP PAIR 2: A <-> C (100 times) ======
        emit log_string("\n\n=== SWAP PAIR 2: A <-> C x 100 ===");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        uint256 postAmountInC; uint256 postAmountOutC;
        uint256 postAmountInA_CA; uint256 postAmountOutA_CA;

        for (uint256 i = 0; i < 100; i++) {
            // Buy all tokenC (A -> C)
            uint256 balanceTokenC = swapVM.balances(orderHash, tokenC);
            // if (i == 0) {
            //     balanceTokenC = setup.balanceC; // First iteration doesn't have balances in state yet
            // }
            swapVM.swap(order, tokenA, tokenC, balanceTokenC, swapData);
            (postAmountInC, postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);

            // Buy all tokenA (C -> A)
            uint256 balanceTokenA = swapVM.balances(orderHash, tokenA);
            swapVM.swap(order, tokenC, tokenA, balanceTokenA, swapData);
            (postAmountInA_CA, postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        }

        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC * ONE / price_AC, "Token C (relative) after 100 swap pairs", true, 0.4e18);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC * ONE / price_AC, "Token A (relative) after 100 swap pairs", false, 0.4e18);

        vm.stopPrank();
    }

    /// @notice Test realistic scenario: 1000 small swaps (5% volume) followed by full drains
    /// @dev This simulates realistic trading activity before testing price bounds
    function test_RealisticSwaps_SmallVolume_ThenFullDrain() public {
        emit log_string("=== Test: 3D Realistic Swaps (1000x 5% volume) + Full Drains ===");

        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: 0,
            priceMax_AB: 0,
            priceMax_AC: 0,
            priceMin_AC: 0,
            priceMin_BC: 0,
            priceMax_BC: 0
        });

        // Calculate current prices
        uint256 price_AB = setup.balanceB * ONE / setup.balanceA;  // 1.5
        uint256 price_AC = setup.balanceC * ONE / setup.balanceA;  // 2.0
        uint256 price_BC = setup.balanceC * ONE / setup.balanceB;  // 1.333...

        // Define relative ranges
        setup.priceMin_AB = price_AB / 4;  // 0.375
        setup.priceMax_AB = price_AB * 4;  // 6.0
        setup.priceMax_AC = price_AC * 6;  // 12.0

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFee(setup, price_AB, price_AC, price_BC);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory quoteData = _quotingTakerData();
        bytes memory swapData = _swappingTakerData(signature);

        _printSetup(setup);

        vm.startPrank(taker);

        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);

        // ====== PHASE 1: 1000 small swaps (5% volume each) B <-> A ======
        emit log_string("\n\n=== PHASE 1: 1000x small swaps (5% volume) B <-> A ===");

        for (uint256 i = 0; i < 1000; i++) {
            uint256 balanceTokenA = swapVM.balances(orderHash, tokenA);
            balanceTokenA = balanceTokenA == 0 ? setup.balanceA : balanceTokenA;
            (uint256 amountIn0, uint256 amountOut0,) = swapVM.swap(order, tokenB, tokenA, balanceTokenA * 5 / 100, swapData);
            (uint256 amountIn1, uint256 amountOut1,) = swapVM.swap(order, tokenA, tokenB, amountIn0, swapData);
            (uint256 amountIn2, uint256 amountOut2,) = swapVM.swap(order, tokenB, tokenC, amountOut1, swapData);
            (uint256 amountIn3, uint256 amountOut3,) = swapVM.swap(order, tokenC, tokenB, amountIn2, swapData);
        }

        emit log_string("\n--- After 1000 small swaps ---");
        emit log_named_decimal_uint("balanceA", swapVM.balances(orderHash, tokenA), 18);
        emit log_named_decimal_uint("balanceB", swapVM.balances(orderHash, tokenB), 18);
        emit log_named_decimal_uint("balanceC", swapVM.balances(orderHash, tokenC), 18);

        // ====== PHASE 2: Full drain swaps to test price bounds ======
        emit log_string("\n\n=== PHASE 2: Full Drain Swaps to Test Price Bounds ===");

        // Test Token A price bound (B -> A full drain)
        emit log_string("\n--- Drain Token A (B -> A) ---");
        uint256 balanceTokenA = swapVM.balances(orderHash, tokenA);
        swapVM.swap(order, tokenB, tokenA, balanceTokenA, swapData);
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB * ONE / price_AB, "Token A1 (relative) after small swaps + drain", false, 0.03e18);

        (uint256 preAmountInA_CA, uint256 preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        // Test Token B price bound (A -> B full drain)
        emit log_string("\n--- Drain Token B (A -> B) ---");
        uint256 balanceTokenB = swapVM.balances(orderHash, tokenB);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapData);
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB * ONE / price_AB, "Token B (relative) after small swaps + drain", true, 0.03e18);

        // Test Token C price bound (A -> C full drain)
        emit log_string("\n--- Drain Token C (A -> C) ---");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        uint256 balanceTokenC = swapVM.balances(orderHash, tokenC);
        swapVM.swap(order, tokenA, tokenC, balanceTokenC, swapData);
        (uint256 postAmountInC, uint256 postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC * ONE / price_AC, "Token C (relative) after small swaps + drain", true, 0.06e18);

        // Test Token A price bound again (C -> A full drain)
        emit log_string("\n--- Drain Token A again (C -> A) ---");
        balanceTokenA = swapVM.balances(orderHash, tokenA);
        swapVM.swap(order, tokenC, tokenA, balanceTokenA, swapData);
        (uint256 postAmountInA_CA, uint256 postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC * ONE / price_AC, "Token A4 (relative) after small swaps + drain", false, 0.03e18);

        vm.stopPrank();
    }
}
