// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { Vm } from "forge-std/Vm.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/**
 * @title XYCConcentrateMultiTokenTest
 * @notice Tests for XYCConcentrate with multi-token orders (>2 tokens)
 * @dev This test suite verifies that liquidity storage is correctly isolated per token pair
 *      to prevent storage collisions when makers create orders supporting swaps between
 *      more than 2 tokens.
 */
contract XYCConcentrateMultiTokenTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    XYCConcentrate public concentrate;

    address public tokenA;
    address public tokenB;
    address public tokenC;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    // Helper to compute liquidity key same way as XYCConcentrate
    function _computeLiquidityKey(bytes32 orderHash, address tokenIn, address tokenOut) internal pure returns (bytes32) {
        (address tokenLt, address tokenGt) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        return keccak256(abi.encodePacked(orderHash, tokenLt, tokenGt));
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router and get concentrate instance
        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");
        concentrate = XYCConcentrate(address(swapVM));

        // Deploy 3 mock tokens
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

        // Approve SwapVM
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

    struct ThreeTokenSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint256 balanceC;
        uint256 flatFee;
    }

    function _createThreeTokenOrder(ThreeTokenSetup memory setup)
        internal
        view
        returns (ISwapVM.Order memory order, bytes memory signature)
    {
        // Compute deltas for each pair with different price bounds
        (uint256 deltaA_forB, uint256 deltaB_forA, uint256 liquidityAB) =
            XYCConcentrateArgsBuilder.computeDeltas(setup.balanceA, setup.balanceB, 1e18, 0.01e18, 25e18);
        (uint256 deltaA_forC, uint256 deltaC_forA, uint256 liquidityAC) =
            XYCConcentrateArgsBuilder.computeDeltas(setup.balanceA, setup.balanceC, 1e18, 0.02e18, 20e18);
        (uint256 deltaB_forC, uint256 deltaC_forB, uint256 liquidityBC) =
            XYCConcentrateArgsBuilder.computeDeltas(setup.balanceB, setup.balanceC, 1e18, 0.05e18, 10e18);

        // Build XD args with all three tokens
        address[] memory tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = tokenC;

        // For simplicity, use average deltas (in real scenario, deltas would be pair-specific)
        uint256[] memory deltas = new uint256[](3);
        deltas[0] = (deltaA_forB + deltaA_forC) / 2;
        deltas[1] = (deltaB_forA + deltaB_forC) / 2;
        deltas[2] = (deltaC_forA + deltaC_forB) / 2;

        uint256 avgLiquidity = (liquidityAB + liquidityAC + liquidityBC) / 3;

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
                    tokens,
                    dynamic([setup.balanceA, setup.balanceB, setup.balanceC])
                )),
                program.build(XYCConcentrate._xycConcentrateGrowLiquidityXD,
                    XYCConcentrateArgsBuilder.buildXD(tokens, deltas, avgLiquidity)
                ),
                program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(setup.flatFee.toUint32())),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(bool isExactIn, bytes memory sig) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
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
            signature: sig
        }));
    }

    function test_ThreeTokens_IndependentLiquidityStorage() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 10000e18,
            balanceB: 5000e18,
            balanceC: 2000e18,
            flatFee: 0.001e9  // 0.1% fee
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory takerData = _buildTakerData(false, signature);

        // Perform swap A -> B (half of B)
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, setup.balanceB / 2, takerData);

        // Get liquidity keys for all pairs
        bytes32 keyAB = _computeLiquidityKey(orderHash, tokenA, tokenB);
        bytes32 keyAC = _computeLiquidityKey(orderHash, tokenA, tokenC);
        bytes32 keyBC = _computeLiquidityKey(orderHash, tokenB, tokenC);

        // Check that liquidity values are different (AB was used, AC and BC were not)
        uint256 liquidityAB = concentrate.liquidity(keyAB);
        uint256 liquidityAC = concentrate.liquidity(keyAC);
        uint256 liquidityBC = concentrate.liquidity(keyBC);

        assertTrue(liquidityAB > 0, "Liquidity A-B should be updated");
        assertEq(liquidityAC, 0, "Liquidity A-C should still be 0");
        assertEq(liquidityBC, 0, "Liquidity B-C should still be 0");
    }

    function test_ThreeTokens_SequentialSwapsAcrossPairs() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 10000e18,
            balanceB: 5000e18,
            balanceC: 2000e18,
            flatFee: 0.001e9
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory takerData = _buildTakerData(false, signature);

        bytes32 keyAB = _computeLiquidityKey(orderHash, tokenA, tokenB);
        bytes32 keyAC = _computeLiquidityKey(orderHash, tokenA, tokenC);
        bytes32 keyBC = _computeLiquidityKey(orderHash, tokenB, tokenC);

        // Swap 1: A -> B
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 1000e18, takerData);
        uint256 liqAB_1 = concentrate.liquidity(keyAB);
        uint256 liqAC_1 = concentrate.liquidity(keyAC);
        uint256 liqBC_1 = concentrate.liquidity(keyBC);

        assertTrue(liqAB_1 > 0, "A-B liquidity should be set after first swap");
        assertEq(liqAC_1, 0, "A-C liquidity should still be 0");
        assertEq(liqBC_1, 0, "B-C liquidity should still be 0");

        // Swap 2: A -> C
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenC, 500e18, takerData);
        uint256 liqAB_2 = concentrate.liquidity(keyAB);
        uint256 liqAC_2 = concentrate.liquidity(keyAC);
        uint256 liqBC_2 = concentrate.liquidity(keyBC);

        assertEq(liqAB_2, liqAB_1, "A-B liquidity should not change");
        assertTrue(liqAC_2 > 0, "A-C liquidity should be set after second swap");
        assertEq(liqBC_2, 0, "B-C liquidity should still be 0");

        // Swap 3: B -> C
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenC, 300e18, takerData);
        uint256 liqAB_3 = concentrate.liquidity(keyAB);
        uint256 liqAC_3 = concentrate.liquidity(keyAC);
        uint256 liqBC_3 = concentrate.liquidity(keyBC);

        assertEq(liqAB_3, liqAB_1, "A-B liquidity should not change");
        assertEq(liqAC_3, liqAC_2, "A-C liquidity should not change");
        assertTrue(liqBC_3 > 0, "B-C liquidity should be set after third swap");
    }

    function test_ThreeTokens_PairIndependenceAfterExhaustion() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 10000e18,
            balanceB: 5000e18,
            balanceC: 2000e18,
            flatFee: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes memory takerData = _buildTakerData(false, signature);

        // Exhaust pair A-B completely
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, setup.balanceB, takerData);
        assertEq(swapVM.balances(swapVM.hash(order), tokenB), 0, "Token B should be exhausted");

        // Verify A-C pair still works
        vm.prank(taker);
        (uint256 amountIn,,) = swapVM.swap(order, tokenA, tokenC, 500e18, takerData);
        assertTrue(amountIn > 0, "A-C swap should still work after A-B exhaustion");

        // Verify B-C pair still works (buying C with B)
        vm.prank(taker);
        (uint256 amountIn2,,) = swapVM.swap(order, tokenB, tokenC, 200e18, takerData);
        assertTrue(amountIn2 > 0, "B-C swap should still work after A-B exhaustion");
    }

    function test_ThreeTokens_CircularSwaps() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 10000e18,
            balanceB: 10000e18,
            balanceC: 10000e18,
            flatFee: 0.001e9
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes memory takerData = _buildTakerData(false, signature);

        uint256 takerBalanceA_init = TokenMock(tokenA).balanceOf(taker);

        // Circular swap: A -> B -> C -> A
        vm.startPrank(taker);

        // A -> B
        (uint256 amountInAB, uint256 amountOutAB,) = swapVM.swap(order, tokenA, tokenB, 1000e18, takerData);

        // B -> C (use all received B tokens)
        (uint256 amountInBC, uint256 amountOutBC,) = swapVM.swap(order, tokenB, tokenC, amountOutAB, takerData);

        // C -> A (use all received C tokens)
        (uint256 amountInCA, uint256 amountOutCA,) = swapVM.swap(order, tokenC, tokenA, amountOutBC, takerData);

        vm.stopPrank();

        // Due to fees and price impact, we should end up with less A than we started with
        uint256 takerBalanceA_final = TokenMock(tokenA).balanceOf(taker);
        uint256 netChange = takerBalanceA_init > takerBalanceA_final
            ? takerBalanceA_init - takerBalanceA_final
            : takerBalanceA_final - takerBalanceA_init;

        // Check that the circular path completed and we got some A back
        assertTrue(amountOutCA > 0, "Should receive some A tokens back");
        assertTrue(netChange < amountInAB, "Net loss should be less than initial input (got something back)");
    }

    function test_ThreeTokens_StressTestMultipleSwaps() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 100000e18,
            balanceB: 100000e18,
            balanceC: 100000e18,
            flatFee: 0.001e9
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory takerData = _buildTakerData(false, signature);

        bytes32 keyAB = _computeLiquidityKey(orderHash, tokenA, tokenB);
        bytes32 keyAC = _computeLiquidityKey(orderHash, tokenA, tokenC);
        bytes32 keyBC = _computeLiquidityKey(orderHash, tokenB, tokenC);

        // Perform 30 swaps across different pairs
        for (uint256 i = 0; i < 30; i++) {
            uint256 pairSelector = i % 3;

            vm.prank(taker);
            if (pairSelector == 0) {
                // A -> B
                swapVM.swap(order, tokenA, tokenB, 100e18, takerData);
            } else if (pairSelector == 1) {
                // B -> C
                swapVM.swap(order, tokenB, tokenC, 100e18, takerData);
            } else {
                // C -> A
                swapVM.swap(order, tokenC, tokenA, 100e18, takerData);
            }
        }

        // Verify all pairs have their own liquidity tracking
        uint256 liqAB = concentrate.liquidity(keyAB);
        uint256 liqBC = concentrate.liquidity(keyBC);
        uint256 liqCA = concentrate.liquidity(keyAC);

        assertTrue(liqAB > 0, "A-B liquidity should be tracked");
        assertTrue(liqBC > 0, "B-C liquidity should be tracked");
        assertTrue(liqCA > 0, "C-A liquidity should be tracked");

        // All should be different (statistical impossibility they're equal after different swaps)
        assertTrue(liqAB != liqBC || liqBC != liqCA, "All liquidities should be independently tracked");
    }

    function test_ThreeTokens_ReverseDirectionSamePair() public {
        ThreeTokenSetup memory setup = ThreeTokenSetup({
            balanceA: 10000e18,
            balanceB: 10000e18,
            balanceC: 10000e18,
            flatFee: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createThreeTokenOrder(setup);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory takerData = _buildTakerData(false, signature);

        bytes32 keyAB = _computeLiquidityKey(orderHash, tokenA, tokenB);

        // Forward: A -> B
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 1000e18, takerData);
        uint256 liqAfterForward = concentrate.liquidity(keyAB);

        // Reverse: B -> A (should use SAME liquidity key)
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, 500e18, takerData);
        uint256 liqAfterReverse = concentrate.liquidity(keyAB);

        // Both directions should update the same liquidity tracking
        assertTrue(liqAfterForward > 0, "Liquidity should be set after forward swap");
        assertTrue(liqAfterReverse != liqAfterForward, "Liquidity should update after reverse swap");
    }
}
