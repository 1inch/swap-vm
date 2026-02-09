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

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/// @title 3D Concentrated Liquidity Tests
/// @notice Tests for _xycConcentrateGrowLiquidity3D with full swap scenarios
contract XYCConcentrate3DTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    uint256 constant ONE = 1e18;

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

    function _createOrder(MakerSetup memory setup, uint256 price_AB, uint256 price_AC, uint256 price_BC) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
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

        assertApproxEqRel(rateChange, expectedRate, 0.005e18, string(abi.encodePacked("Rate change should match for ", label)));
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
    }

    /// @notice Test full swap with rate changes for 3 tokens (absolute prices)
    function test_FullSwap_RateChanges() public {
        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: ONE / 4,  // 0.25
            priceMax_AB: 4 * ONE,
            priceMax_AC: 6 * ONE,
            priceMin_AC: 0,  // Will be calced
            priceMin_BC: 0,  // Will be calced
            priceMax_BC: 0   // Will be calced
        });

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup, ONE, ONE, ONE);
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

        (preAmountInA, preAmountOutA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

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
        (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AC, "Token A", false);

        vm.stopPrank();
    }

    /// @notice Test full swap with current prices (relative bounds) for 3D
    function test_FullSwap_RateChanges_CurrentPrice() public {
        emit log_string("=== Test: 3D Full Swap with Current Prices (Relative Bounds) ===");

        // Setup with different balances to have different prices
        MakerSetup memory setup = MakerSetup({
            balanceA: 100 * ONE,
            balanceB: 150 * ONE,
            balanceC: 200 * ONE,
            priceMin_AB: 0, // Will be calced below
            priceMax_AB: 0, // Will be calced below
            priceMax_AC: 0, // Will be calced below
            priceMin_AC: 0, // Will be calced in _createOrder
            priceMin_BC: 0, // Will be calced in _createOrder
            priceMax_BC: 0  // Will be calced in _createOrder
        });

        // Calculate current prices
        uint256 price_AB = setup.balanceB * ONE / setup.balanceA;  // 1.5
        uint256 price_AC = setup.balanceC * ONE / setup.balanceA;  // 2.0
        uint256 price_BC = setup.balanceC * ONE / setup.balanceB;  // 1.333...

        // Define relative ranges (4x for A/B, 6x for A/C)
        setup.priceMin_AB = price_AB / 4;  // 0.375
        setup.priceMax_AB = price_AB * 4;  // 6.0
        setup.priceMax_AC = price_AC * 6;  // 12.0

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup, price_AB, price_AC, price_BC);
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

        (preAmountInA, preAmountOutA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

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
        (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, tokenC, tokenA, 0.000001e18, quoteData);

        _verifyRateChange(preAmountInA, preAmountOutA, postAmountInA, postAmountOutA, setup.priceMin_AC * ONE / price_AC, "Token A (relative)", false);

        vm.stopPrank();
    }
}
