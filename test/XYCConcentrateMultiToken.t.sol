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
        // Use chain calculation for consistent deltas across all pairs
        // Compute current price for base pair A-B
        uint256 basePairPrice = (setup.balanceB * 1e18) / setup.balanceA;

        // Compute deltas for base pair and get concentration ratio
        (uint256 deltaA, uint256 deltaB, uint256 concentrationRatio) =
            XYCConcentrateArgsBuilder.computeDeltasChain(
                setup.balanceA,    // balance of token A
                setup.balanceB,    // balance of token B
                basePairPrice,     // current price A-B
                0.01e18,           // min price = 0.01 (very wide range)
                25e18              // max price = 25.0
            );

        // Apply concentration ratio to token C
        uint256 deltaC = (setup.balanceC * (concentrationRatio - 1e18)) / 1e18;

        // Build arrays for XD format
        address[] memory tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = tokenC;

        uint256[] memory deltas = new uint256[](3);
        deltas[0] = deltaA;
        deltas[1] = deltaB;
        deltas[2] = deltaC;

        uint256[] memory initialBalances = new uint256[](3);
        initialBalances[0] = setup.balanceA + deltaA;
        initialBalances[1] = setup.balanceB + deltaB;
        initialBalances[2] = setup.balanceC + deltaC;

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
                    XYCConcentrateArgsBuilder.buildXD(tokens, deltas, initialBalances)
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

        // Check concentrated balances - A and B were used, C was not
        uint256 concentratedA = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concentratedB = concentrate.concentratedBalances(orderHash, tokenB);
        uint256 concentratedC = concentrate.concentratedBalances(orderHash, tokenC);

        assertTrue(concentratedA > 0, "Token A concentrated balance should be updated");
        assertTrue(concentratedB > 0, "Token B concentrated balance should be updated");
        assertEq(concentratedC, 0, "Token C concentrated balance should still be 0");
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

        // Swap 1: A -> B
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 1000e18, takerData);

        uint256 concA_1 = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB_1 = concentrate.concentratedBalances(orderHash, tokenB);
        uint256 concC_1 = concentrate.concentratedBalances(orderHash, tokenC);

        assertTrue(concA_1 > 0, "Token A should be updated after first swap");
        assertTrue(concB_1 > 0, "Token B should be updated after first swap");
        assertEq(concC_1, 0, "Token C should still be 0");

        // Swap 2: A -> C
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenC, 500e18, takerData);

        uint256 concA_2 = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB_2 = concentrate.concentratedBalances(orderHash, tokenB);
        uint256 concC_2 = concentrate.concentratedBalances(orderHash, tokenC);

        assertTrue(concA_2 > concA_1, "Token A should increase (used in both swaps)");
        assertEq(concB_2, concB_1, "Token B should not change");
        assertTrue(concC_2 > 0, "Token C should be set after second swap");

        // Swap 3: B -> C
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenC, 300e18, takerData);

        uint256 concA_3 = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB_3 = concentrate.concentratedBalances(orderHash, tokenB);
        uint256 concC_3 = concentrate.concentratedBalances(orderHash, tokenC);

        assertEq(concA_3, concA_2, "Token A should not change");
        assertTrue(concB_3 != concB_2, "Token B should update");
        assertTrue(concC_3 < concC_2, "Token C balance should decrease");
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

        // Verify all tokens have concentrated balances tracked
        uint256 concA = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB = concentrate.concentratedBalances(orderHash, tokenB);
        uint256 concC = concentrate.concentratedBalances(orderHash, tokenC);

        assertTrue(concA > 0, "Token A concentrated balance should be tracked");
        assertTrue(concB > 0, "Token B concentrated balance should be tracked");
        assertTrue(concC > 0, "Token C concentrated balance should be tracked");

        // All should be different (statistical impossibility they're equal after different swap patterns)
        assertTrue(concA != concB || concB != concC, "All token balances should be independently tracked");
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

        // Forward: A -> B
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, 1000e18, takerData);

        uint256 concA_forward = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB_forward = concentrate.concentratedBalances(orderHash, tokenB);

        // Reverse: B -> A (should update same token balances)
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, 500e18, takerData);

        uint256 concA_reverse = concentrate.concentratedBalances(orderHash, tokenA);
        uint256 concB_reverse = concentrate.concentratedBalances(orderHash, tokenB);

        // Both directions should update the same token tracking
        assertTrue(concA_forward > 0, "Token A should be set after forward swap");
        assertTrue(concB_forward > 0, "Token B should be set after forward swap");
        assertTrue(concA_reverse < concA_forward, "Token A should decrease after reverse swap");
        assertTrue(concB_reverse > concB_forward, "Token B should increase after reverse swap");
    }
}
