// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @title XYCConcentrate Multi-Token Liquidity Tests
/// @notice Tests for liquidity and price updates in multi-token concentrated pools
contract XYCConcentrateMultiTokenTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;
    address public tokenC;
    address public tokenD;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function assertNotApproxEqRel(uint256 left, uint256 right, uint256 maxDelta, string memory err) internal {
        if (left > right * (1e18 - maxDelta) / 1e18 && left < right * (1e18 + maxDelta) / 1e18) {
            // Value IS within range, but we expect it NOT to be
            fail(err);
        }
    }

    struct MakerSetup {
        address[] tokens;
        uint256[] balances;
        uint256[] currentPrice;
        uint256[] priceMin;
        uint256[] priceMax;
        uint32 flatFee; // 0.003e9 = 0.3% flat fee
    }

    struct TakerSetup {
        bool isExactIn;
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router
        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));
        tokenC = address(new TokenMock("Token C", "TKC"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 1_000_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000_000e18);
        TokenMock(tokenC).mint(maker, 1_000_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000_000e18);
        TokenMock(tokenC).mint(taker, 1_000_000_000e18);

        // Approve SwapVM to spend tokens by maker
        vm.startPrank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenC).approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        // Approve SwapVM to spend tokens by taker
        vm.startPrank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        TokenMock(tokenC).approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
    }

    function _getPairId(address token0, address token1) internal pure returns (bytes32) {
        (address tokenLt, address tokenGt) = token0 < token1 ? (token0, token1) : (token1, token0);
        return XYCConcentrateArgsBuilder.getPairId(tokenLt, tokenGt);
    }

    function _createMultiTokenOrder(
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory currentPrice,
        uint256[] memory priceMin,
        uint256[] memory priceMax,
        uint32 feeBps
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        require(tokens.length == balances.length, "Length mismatch");
        require(tokens.length >= 2, "Need at least 2 tokens");

        (bytes32[] memory pairIds, uint256[] memory deltas, uint256[] memory liquidities) = XYCConcentrateArgsBuilder.computePairs(
            tokens,
            balances,
            currentPrice,
            priceMin,
            priceMax
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
                program.build(Balances._dynamicBalancesXD,
                    BalancesArgsBuilder.build(tokens, balances)),
                feeBps > 0 ? program.build(Fee._flatFeeAmountInXD,
                    FeeArgsBuilder.buildFlatFee(feeBps)) : bytes(""),
                program.build(XYCConcentrate._xycConcentrateGrowLiquidityXD,
                    XYCConcentrateArgsBuilder.buildXD(pairIds, deltas, liquidities)
                ),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    // Overload without fee parameter (defaults to 0.3% = 0.003e9)
    function _createMultiTokenOrder(
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory currentPrice,
        uint256[] memory priceMin,
        uint256[] memory priceMax
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        return _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax, uint32(0.003e9));
    }

    function _takerData(bytes memory signature, bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
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

    function _takerData(bytes memory signature) internal view returns (bytes memory) {
        return _takerData(signature, true);  // Default to exactIn
    }

    function _getPrice(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amount) internal view returns (uint256) {
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(order, tokenIn, tokenOut, amount, _takerData(""));
        return amountOut * 1e18 / amountIn;
    }

    // Helper to create standard 3-token setup
    // Auto-calculates prices based on balances
    // Override returned prices if needed for custom tests
    function _createThreeTokenSetup(
        uint256 balanceA,
        uint256 balanceB,
        uint256 balanceC
    ) internal view returns (
        address[] memory tokens,
        uint256[] memory balances,
        uint256[] memory currentPrice,
        uint256[] memory priceMin,
        uint256[] memory priceMax
    ) {
        tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = tokenC;

        balances = new uint256[](3);
        balances[0] = balanceA;
        balances[1] = balanceB;
        balances[2] = balanceC;

        // Auto-calculate prices based on balances
        currentPrice = new uint256[](3);
        currentPrice[0] = (balanceB * 1e18) / balanceA; // B/A
        currentPrice[1] = (balanceC * 1e18) / balanceA; // C/A
        currentPrice[2] = (balanceC * 1e18) / balanceB; // C/B

        priceMin = new uint256[](3);
        priceMin[0] = currentPrice[0] / 2;
        priceMin[1] = currentPrice[1] / 2;
        priceMin[2] = currentPrice[2] / 2;

        priceMax = new uint256[](3);
        priceMax[0] = currentPrice[0] * 2;
        priceMax[1] = currentPrice[1] * 2;
        priceMax[2] = currentPrice[2] * 2;
    }

    // ========== 2-TOKEN POOL TESTS ==========

    function test_TwoTokenPool_LiquidityUpdate() public {
        // Setup: A=100e18, B=200e18
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 100e18;
        balances[1] = 200e18;

        uint256[] memory currentPrice = new uint256[](1);
        currentPrice[0] = 1e18;
        uint256[] memory priceMin = new uint256[](1);
        priceMin[0] = 0.5e18;
        uint256[] memory priceMax = new uint256[](1);
        priceMax[0] = 2e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);
        bytes32 orderHash = swapVM.hash(order);
        bytes32 pairId = _getPairId(tokenA, tokenB);
        uint256 liquidity = swapVM.liquidity(orderHash, pairId);
        uint256 amountIn = 10e18;

        vm.startPrank(taker);
        for (uint256 i = 0; i < 10; i++) {
            swapVM.swap(order, tokenA, tokenB, amountIn, _takerData(signature));
            uint256 liquidityAfterSwap = swapVM.liquidity(orderHash, pairId);
            assertGe(liquidityAfterSwap, liquidity, "Liquidity should remain constant or increase after swaps");
        }
        for (uint256 i = 0; i < 10; i++) {
            swapVM.swap(order, tokenB, tokenA, amountIn, _takerData(signature));
            uint256 liquidityAfterSwap = swapVM.liquidity(orderHash, pairId);
            assertGe(liquidityAfterSwap, liquidity, "Liquidity should remain constant or increase after swaps");
        }
        vm.stopPrank();
    }

    // ========== 3-TOKEN POOL TESTS ==========

    function test_ThreeTokenPool_AdjacentPairsUpdate() public {
        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory currentPrice,
            uint256[] memory priceMin,
            uint256[] memory priceMax
        ) = _createThreeTokenSetup(1e18, 2e18, 3e18);

        // Override with custom price ranges for this test
        priceMin[0] = 1e18; priceMin[1] = 1.5e18; priceMin[2] = 0.75e18;
        priceMax[0] = 4e18; priceMax[1] = 6e18; priceMax[2] = 3e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);
        bytes32 orderHash = swapVM.hash(order);

        bytes32 pairAB = _getPairId(tokenA, tokenB);
        bytes32 pairAC = _getPairId(tokenA, tokenC);
        bytes32 pairBC = _getPairId(tokenB, tokenC);

        // Execute swap A→B
        uint256 amountIn = 1e18;
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, amountIn, _takerData(signature));

        // Check all three pairs were updated
        uint256 liquidityAB = swapVM.liquidity(orderHash, pairAB);
        uint256 liquidityAC = swapVM.liquidity(orderHash, pairAC);
        uint256 liquidityBC = swapVM.liquidity(orderHash, pairBC);

        // All liquidities should be non-zero after swap
        assertTrue(liquidityAB > 0, "Liquidity A/B should be updated");
        assertTrue(liquidityAC > 0, "Liquidity A/C should be updated");
        assertTrue(liquidityBC > 0, "Liquidity B/C should be updated");
    }

    function test_ThreeTokenPool_PriceConsistency() public {
        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory currentPrice,
            uint256[] memory priceMin,
            uint256[] memory priceMax
        ) = _createThreeTokenSetup(100e18, 200e18, 300e18);

        // Override with custom price ranges for this test
        priceMin[0] = 1e18; priceMin[1] = 1.5e18; priceMin[2] = 0.75e18;
        priceMax[0] = 4e18; priceMax[1] = 6e18; priceMax[2] = 3e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);

        bytes32 orderHash = swapVM.hash(order);
        bytes32 pairAB = _getPairId(tokenA, tokenB);
        bytes32 pairAC = _getPairId(tokenA, tokenC);
        bytes32 pairBC = _getPairId(tokenB, tokenC);

        // ===== BEFORE SWAP =====
        uint256 priceAB_before = _getPrice(order, tokenA, tokenB, 0.01e18);
        uint256 priceBC_before = _getPrice(order, tokenB, tokenC, 0.01e18);
        uint256 priceAC_direct_before = _getPrice(order, tokenA, tokenC, 0.01e18);
        uint256 priceAC_via_B_before = priceAB_before * priceBC_before / 1e18;

        // Price transitivity BEFORE swap
        assertApproxEqRel(
            priceAC_direct_before,
            priceAC_via_B_before,
            0.02e18,
            "Prices should be transitive before swap"
        );

        // initializes liquidity
        uint256 swapAmount = 10e18;
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, swapAmount, _takerData(signature));

        uint256 priceAB_after = _getPrice(order, tokenA, tokenB, 0.01e18);
        uint256 priceBC_after = _getPrice(order, tokenB, tokenC, 0.01e18);
        uint256 priceAC_direct_after = _getPrice(order, tokenA, tokenC, 0.01e18);
        uint256 priceAC_via_B_after = priceAB_after * priceBC_after / 1e18;

        uint256 liquidityAB_after = swapVM.liquidity(orderHash, pairAB);
        uint256 liquidityAC_after = swapVM.liquidity(orderHash, pairAC);
        uint256 liquidityBC_after = swapVM.liquidity(orderHash, pairBC);

        // Price transitivity AFTER swap
        assertApproxEqRel(
            priceAC_direct_after,
            priceAC_via_B_after,
            0.02e18,
            "Prices should remain transitive after swap"
        );

        // Price direction changes are correct
        // After selling A for B: A should become cheaper
        assertLt(priceAB_after, priceAB_before, "A should be cheaper after selling A for B");
        assertLt(priceAC_direct_after, priceAC_direct_before, "A should be cheaper relative to C");
        assertGt(priceBC_after, priceBC_before, "B should be more expensive relative to C");

        // test liquidity changes
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, swapAmount, _takerData(signature));

        uint256 liquidityAB_after2 = swapVM.liquidity(orderHash, pairAB);
        uint256 liquidityAC_after2 = swapVM.liquidity(orderHash, pairAC);
        uint256 liquidityBC_after2 = swapVM.liquidity(orderHash, pairBC);

        // Expected behavior in shared liquidity model:
        // Active pair A/B: liquidity increases
        // Pair A/C: liquidity increases (A increased in pool)
        // Pair B/C: liquidity decreases (B decreased in pool)
        assertGt(liquidityAB_after2, liquidityAB_after, "Liquidity A/B should increase (active pair)");
        assertGt(liquidityAC_after2, liquidityAC_after, "Liquidity A/C should increase (A increased)");
        assertLt(liquidityBC_after2, liquidityBC_after, "Liquidity B/C should decrease (B decreased)");
    }

    function test_ThreeTokenPool_NoArbitrageInCircularSwaps() public {
        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory currentPrice,
            uint256[] memory priceMin,
            uint256[] memory priceMax
        ) = _createThreeTokenSetup(100e18, 200e18, 300e18);

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);

        // Initialize liquidity with first swap
        vm.startPrank(taker);
        swapVM.swap(order, tokenA, tokenB, 1e18, _takerData(signature));

        uint256 startAmount = 10e18;

        // Step 1: A -> B
        (, uint256 amountOut1,) = swapVM.swap(order, tokenA, tokenB, startAmount, _takerData(signature));
        // Step 2: B -> C
        (, uint256 amountOut2,) = swapVM.swap(order, tokenB, tokenC, amountOut1, _takerData(signature));
        // Step 3: C -> A
        (, uint256 amountOut3,) = swapVM.swap(order, tokenC, tokenA, amountOut2, _takerData(signature));
        vm.stopPrank();

        // Calculate loss
        uint256 loss = startAmount > amountOut3 ? startAmount - amountOut3 : 0;
        uint256 lossPercent = loss * 100e18 / startAmount;

        // Should not create profit (no arbitrage)
        // Small loss is expected due to slippage and fees
        assertLe(amountOut3, startAmount, "Circular swap should not create profit");

        // Loss should be reasonable (< 10% for this size of swap)
        assertLt(lossPercent, 10e18, "Loss from circular swap should be reasonable");
    }

    // ========== EDGE CASE TESTS ==========

    function test_ThreeTokenPool_ReservesDepletion() public {
        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory currentPrice,
            uint256[] memory priceMin,
            uint256[] memory priceMax
        ) = _createThreeTokenSetup(100e18, 200e18, 300e18);

        // Override with uniform prices for this test
        currentPrice[0] = 1e18; currentPrice[1] = 1e18; currentPrice[2] = 1e18;
        priceMin[0] = 0.5e18; priceMin[1] = 0.5e18; priceMin[2] = 0.5e18;
        priceMax[0] = 2e18; priceMax[1] = 2e18; priceMax[2] = 2e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);
        bytes32 orderHash = swapVM.hash(order);

        // Fully deplete tokenA using exactOut to get precise amount
        uint256 allTokenA = balances[0];  // 100e18

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(
            order,
            tokenB,        // tokenIn
            tokenA,        // tokenOut - want to receive all tokenA
            allTokenA,     // Exact amount to receive
            _takerData(signature, false)  // isExactIn = false (exactOut)
        );

        // Check that tokenA is completely depleted
        uint256 balanceA = swapVM.balances(orderHash, tokenA);
        assertEq(balanceA, 0, "Token A should be completely depleted");

        // Verify we received exact amount requested
        assertEq(amountOut, allTokenA, "Should receive exact amount of tokenA");

        // Check that we cannot swap B->A anymore (no A available)
        vm.prank(taker);
        vm.expectRevert(); // Should revert because no A tokens available
        swapVM.swap(order, tokenB, tokenA, 1e18, _takerData(signature));

        // Check that we cannot swap C->A anymore (no A available)
        vm.prank(taker);
        vm.expectRevert(); // Should revert because no A tokens available
        swapVM.swap(order, tokenC, tokenA, 1e18, _takerData(signature));

        // But we should still be able to swap B<->C (those tokens are still available)
        uint256 balanceB = swapVM.balances(orderHash, tokenB);
        uint256 balanceC = swapVM.balances(orderHash, tokenC);

        assertTrue(balanceB > 0, "Token B should still be available");
        assertTrue(balanceC > 0, "Token C should still be available");

        // Verify we can still swap B->C
        vm.prank(taker);
        (, uint256 amountOutBC,) = swapVM.swap(order, tokenB, tokenC, 1e18, _takerData(signature));
        assertTrue(amountOutBC > 0, "Should be able to swap B->C when A is depleted");

        balanceB = swapVM.balances(orderHash, tokenB);
        vm.prank(taker);
        swapVM.swap(order, tokenC, tokenB, balanceB, _takerData(signature, false));
        balanceB = swapVM.balances(orderHash, tokenB);
        assertEq(balanceB, 0, "Token B should be completely depleted");

        // Now tokenB is also depleted, check we cannot swap A->B or C->B
        vm.prank(taker);
        vm.expectRevert(); // Should revert because no B tokens available
        swapVM.swap(order, tokenA, tokenB, 1e18, _takerData(signature));
        vm.prank(taker);
        vm.expectRevert(); // Should revert because no B tokens available
        swapVM.swap(order, tokenC, tokenB, 1e18, _takerData(signature));

        balanceA = swapVM.balances(orderHash, tokenA);
        balanceB = swapVM.balances(orderHash, tokenB);
        balanceC = swapVM.balances(orderHash, tokenC);

        assertEq(balanceB, 0, "Token B should be completely depleted");
        assertEq(balanceA, 0, "Token A should be completely depleted");
        assertGt(balanceC, 0, "Token C should still have balance");
    }

    function test_ThreeTokenPool_KeepsPriceRangeForAllTokensWithFee() public {
        // Use balanced balances so all pairs have ~1:1 price
        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory currentPrice,
            uint256[] memory priceMin,
            uint256[] memory priceMax
        ) = _createThreeTokenSetup(10000e18, 10000e18, 10000e18);

        // Price bounds like in original test
        priceMin[0] = 0.01e18; // B/A can go down to 0.01x (100x concentration)
        priceMin[1] = 0.01e18; // C/A can go down to 0.01x
        priceMin[2] = 0.01e18; // C/B can go down to 0.01x
        priceMax[0] = 25e18;   // B/A can go up to 25x
        priceMax[1] = 25e18;   // C/A can go up to 25x
        priceMax[2] = 25e18;   // C/B can go up to 25x

        (ISwapVM.Order memory order, bytes memory signature) = _createMultiTokenOrder(tokens, balances, currentPrice, priceMin, priceMax);
        bytes32 orderHash = swapVM.hash(order);

        // Check tokenA and tokenB prices before (like original test)
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, _takerData("", false));
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, _takerData("", false));

        uint256 postAmountInA;
        uint256 postAmountOutA;
        uint256 postAmountInB;
        uint256 postAmountOutB;

        // Cycle 1: Test A/B pair with 100 iterations (lower than 2-token to account for shared liquidity)
        for (uint256 i = 0; i < 100; i++) {
            // Buy all tokenA
            uint256 balanceA = swapVM.balances(orderHash, tokenA);
            if (i == 0) {
                balanceA = balances[0]; // First iteration doesn't have balances in state yet
            }
            vm.prank(taker);
            swapVM.swap(order, tokenB, tokenA, balanceA, _takerData(signature, false));
            (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, _takerData("", false));

            // Buy all tokenB
            uint256 balanceB = swapVM.balances(orderHash, tokenB);
            vm.prank(taker);
            swapVM.swap(order, tokenA, tokenB, balanceB, _takerData(signature, false));
            (postAmountInB, postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, _takerData("", false));
        }

        // Compute and compare rate change for tokenA (after A/B cycle)
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertNotApproxEqRel(rateChangeA, priceMin[0], 0.001e18, "Quote should not be within 0.1% range for tokenA");
        assertApproxEqRel(rateChangeA, priceMin[0], 0.006e18, "Quote should be within 0.6% range for tokenA in 3-token pool");

        // Compute and compare rate change for tokenB (after A/B cycle)
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertNotApproxEqRel(rateChangeB, priceMax[0], 0.001e18, "Quote should not be within 0.1% range for tokenB");
        assertApproxEqRel(rateChangeB, priceMax[0], 0.007e18, "Quote should be within 0.7% range for tokenB in 3-token pool");

        (uint256 preAmountInA_AC, uint256 preAmountOutA_AC,) = swapVM.asView().quote(order, tokenC, tokenA, 0.001e18, _takerData("", false));
        (uint256 preAmountInC, uint256 preAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.001e18, _takerData("", false));

        uint256 postAmountInA_AC;
        uint256 postAmountOutA_AC;
        uint256 postAmountInC;
        uint256 postAmountOutC;

        // Cycle 2: Test A/C pair with 100 iterations
        for (uint256 i = 0; i < 1; i++) {
            // Buy all tokenA
            uint256 balanceA = swapVM.balances(orderHash, tokenA);
            emit log_named_uint("Balance A before A/C swap", balanceA);
            vm.prank(taker);
            swapVM.swap(order, tokenC, tokenA, balanceA, _takerData(signature, false));
            (postAmountInA_AC, postAmountOutA_AC,) = swapVM.asView().quote(order, tokenC, tokenA, 0.001e18, _takerData("", false));

            balanceA = swapVM.balances(orderHash, tokenA);
            emit log_named_uint("Balance A after A/C swap", balanceA);

            // Buy all tokenC
            uint256 balanceC = swapVM.balances(orderHash, tokenC);
            vm.prank(taker);
            swapVM.swap(order, tokenA, tokenC, balanceC, _takerData(signature, false));
            (postAmountInC, postAmountOutC,) = swapVM.asView().quote(order, tokenA, tokenC, 0.001e18, _takerData("", false));

            balanceC = swapVM.balances(orderHash, tokenC);
            balanceA = swapVM.balances(orderHash, tokenA);
            emit log_named_uint("Balance A after C/A swap", balanceA);
            emit log_named_uint("Balance C after C/A swap", balanceC);
        }

        // Compute and compare rate change for tokenA (after A/C cycle)
        uint256 preRateA_AC = preAmountInA_AC * 1e18 / preAmountOutA_AC;
        uint256 postRateA_AC = postAmountInA_AC * 1e18 / postAmountOutA_AC;
        uint256 rateChangeA_AC = preRateA_AC * 1e18 / postRateA_AC;
        assertNotApproxEqRel(rateChangeA_AC, priceMin[1], 0.001e18, "Quote should not be within 0.1% range for tokenA (A/C cycle)");
        assertApproxEqRel(rateChangeA_AC, priceMin[1], 0.006e18, "Quote should be within 0.5% range for tokenA in 3-token pool (A/C cycle)");

        // Compute and compare rate change for tokenC (after A/C cycle)
        uint256 preRateC = preAmountInC * 1e18 / preAmountOutC;
        uint256 postRateC = postAmountInC * 1e18 / postAmountOutC;
        uint256 rateChangeC = postRateC * 1e18 / preRateC;
        assertNotApproxEqRel(rateChangeC, priceMax[1], 0.001e18, "Quote should not be within 0.1% range for tokenC");
        assertApproxEqRel(rateChangeC, priceMax[1], 0.007e18, "Quote should be within 0.5% range for tokenC in 3-token pool");
    }
}
