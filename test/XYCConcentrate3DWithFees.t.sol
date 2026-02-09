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
        uint256 liquidityRoot;
        uint256 liquidityPower;
        (
            deltaA,
            deltaB,
            deltaC,
            setup.priceMin_AC,
            setup.priceMin_BC,
            setup.priceMax_BC,
            liquidityRoot,
            liquidityPower
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
                // Add flat fee instruction
                program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(uint32(FEE_BPS))),
                program.build(XYCConcentrate._xycConcentrateGrowLiquidity3D, XYCConcentrateArgsBuilder.buildXD(
                    dynamic([address(tokenA), address(tokenB), address(tokenC)]),
                    dynamic([deltaA, deltaB, deltaC]),
                    liquidityRoot, liquidityPower
                )),
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
        bool isReverseDirection
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

        assertApproxEqRel(rateChange, expectedRate, 0.01e18, string(abi.encodePacked("Rate change should match for ", label)));
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
        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB, "Token A", false);

        (uint256 preAmountInA_CA, uint256 preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");
        swapVM.swap(order, tokenA, tokenB, swapVM.balances(orderHash, tokenB), swapData);
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB, "Token B", true);

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        swapVM.swap(order, tokenA, tokenC, swapVM.balances(orderHash, tokenC), swapData);
        (uint256 postAmountInC, uint256 postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC, "Token C", true);

        // ====== SWAP 4: C -> A (fully drain A again) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A again) ===");
        swapVM.swap(order, tokenC, tokenA, swapVM.balances(orderHash, tokenA), swapData);
        (uint256 postAmountInA_CA, uint256 postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC, "Token A", false);

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
        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AB * ONE / price_AB, "Token A (relative)", false);

        (uint256 preAmountInA_CA, uint256 preAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        // ====== SWAP 2: A -> B (fully drain B) ======
        emit log_string("\n\n=== SWAP 2: A -> B (drain all B) ===");
        swapVM.swap(order, tokenA, tokenB, swapVM.balances(orderHash, tokenB), swapData);
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInB, preAmountOutB, postAmountInB, postAmountOutB, setup.priceMax_AB * ONE / price_AB, "Token B (relative)", true);

        // ====== SWAP 3: A -> C (fully drain C) ======
        emit log_string("\n\n=== SWAP 3: A -> C (drain all C) ===");
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        swapVM.swap(order, tokenA, tokenC, swapVM.balances(orderHash, tokenC), swapData);
        (uint256 postAmountInC, uint256 postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInC, preAmountOutC, postAmountInC, postAmountOutC, setup.priceMax_AC * ONE / price_AC, "Token C (relative)", true);

        // ====== SWAP 4: C -> A (fully drain A again) ======
        emit log_string("\n\n=== SWAP 4: C -> A (drain all A again) ===");
        swapVM.swap(order, tokenC, tokenA, swapVM.balances(orderHash, tokenA), swapData);
        (uint256 postAmountInA_CA, uint256 postAmountOutA_CA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);
        _verifyRateChange(preAmountInA_CA, preAmountOutA_CA, postAmountInA_CA, postAmountOutA_CA, setup.priceMin_AC * ONE / price_AC, "Token A (relative)", false);

        vm.stopPrank();
    }

    /// @notice Test multiple swaps with fee accumulation
    function test_MultipleSwaps_FeeAccumulation() public {
        emit log_string("=== Test: Multiple Swaps with Fee Accumulation ===");

        // Setup: balanced pool for clearer testing
        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 100 * ONE,
            balanceC: 100 * ONE,
            priceMin_AB: ONE / 2,
            priceMax_AB: 2 * ONE,
            priceMax_AC: 2 * ONE,
            priceMin_AC: 0,
            priceMin_BC: 0,
            priceMax_BC: 0
        });

        (ISwapVM.Order memory order, bytes memory signature) = _createOrderWithFee(setup, ONE, ONE, ONE);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory swapData = _swappingTakerData(signature);

        _printSetup(setup);

        vm.startPrank(taker);

        uint256 liquidity0 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("\nInitial liquidity", liquidity0, 18);

        // Perform 5 small swaps
        emit log_string("\n=== SWAP 1: B -> A (10 tokens) ===");
        swapVM.swap(order, tokenB, tokenA, 10e18, swapData);
        uint256 liquidity1 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("Liquidity after swap 1", liquidity1, 18);

        emit log_string("\n=== SWAP 2: A -> C (5 tokens) ===");
        swapVM.swap(order, tokenA, tokenC, 5e18, swapData);
        uint256 liquidity2 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("Liquidity after swap 2", liquidity2, 18);

        emit log_string("\n=== SWAP 3: C -> B (7 tokens) ===");
        swapVM.swap(order, tokenC, tokenB, 7e18, swapData);
        uint256 liquidity3 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("Liquidity after swap 3", liquidity3, 18);

        emit log_string("\n=== SWAP 4: B -> A (3 tokens) ===");
        swapVM.swap(order, tokenB, tokenA, 3e18, swapData);
        uint256 liquidity4 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("Liquidity after swap 4", liquidity4, 18);

        emit log_string("\n=== SWAP 5: A -> C (8 tokens) ===");
        swapVM.swap(order, tokenA, tokenC, 8e18, swapData);
        uint256 liquidity5 = swapVM.liquidity(orderHash);
        emit log_named_decimal_uint("Liquidity after swap 5", liquidity5, 18);

        // Verify liquidity grows after first swap (from 0) and then stays relatively stable
        assertGt(liquidity1, 0, "Liquidity should be > 0 after first swap");
        assertGe(liquidity2, liquidity1 * 99 / 100, "Liquidity should not decrease significantly after swap 2");
        assertGe(liquidity3, liquidity2 * 99 / 100, "Liquidity should not decrease significantly after swap 3");
        assertGe(liquidity4, liquidity3 * 99 / 100, "Liquidity should not decrease significantly after swap 4");
        assertGe(liquidity5, liquidity4 * 99 / 100, "Liquidity should not decrease significantly after swap 5");

        emit log_string("\n=== Liquidity Analysis ===");
        emit log_named_decimal_uint("Initial liquidity", liquidity0, 18);
        emit log_named_decimal_uint("Final liquidity", liquidity5, 18);

        // Calculate percentage change relative to liquidity after first swap
        if (liquidity1 > 0) {
            uint256 changePercent = (liquidity5 * 100 / liquidity1);
            emit log_named_decimal_uint("Liquidity change % (vs swap1)", changePercent, 0);
        }

        vm.stopPrank();
    }
}
