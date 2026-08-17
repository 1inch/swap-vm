// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenIn, InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { FulfillBonusBalanceIn, FulfillBonusBalanceOut } from "../src/instructions/FulfillBonus.sol";

/**
 * @title FulfillBonusTest
 * @notice Tests for FulfillBonusBalanceIn / FulfillBonusBalanceOut instructions
 * @dev All-or-nothing fulfillment bonus: partial fills settle at the plain balance rate,
 *   any ask reaching the fulfillment amount settles the whole order at the incentivized rate.
 *   The BalanceIn variant discounts the input balance, the BalanceOut variant grosses up
 *   the output balance to the same rate. Exact-in and exact-out queries of both variants
 *   settle on the same curve.
 *
 *   Order used everywhere below: 100e18 tokenA in -> 200e18 tokenB out (A->B).
 *   10% incentive: fulfillment pairs are (90e18, 200e18) and (100e18, 222222222222222222222).
 */
contract FulfillBonusTest is Test {
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint24 constant INCENTIVE = 0.1e7; // 10%
    uint256 constant BONUS_OUT_FULL = 222222222222222222222; // 200e18 + 200e18 * 0.1e7 / 0.9e7

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e31);
        tokenB.mint(maker, 1e31);
        tokenA.mint(taker, 1e31);
        tokenB.mint(taker, 1e31);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _bonusInOrder(uint24 incentiveBps) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FulfillBonusBalanceIn.build(incentiveBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
    }

    function _bonusOutOrder(uint24 incentiveBps) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FulfillBonusBalanceOut.build(incentiveBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
    }

    // === Fulfillment asks earn the whole incentive in every branch ===

    function test_FulfillBonus_Fulfillment_AllBranches() public {
        // BonusIn, exactIn: fulfillment ask is the discounted input balance
        ISwapVM.Order memory order = _bonusInOrder(INCENTIVE);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 90e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 90e18);
        assertEq(amountOut, 200e18, "BonusIn exactIn fulfillment");

        // BonusIn, exactOut: fulfillment ask is the plain output balance
        order = _bonusInOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 90e18, "BonusIn exactOut fulfillment");
        assertEq(amountOut, 200e18);

        // BonusOut, exactIn: fulfillment ask is the plain input balance
        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 100e18);
        assertEq(amountOut, BONUS_OUT_FULL, "BonusOut exactIn fulfillment");

        // BonusOut, exactOut: fulfillment ask is the grossed-up output balance
        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, BONUS_OUT_FULL, _makeTakerData(order, false, false));
        assertEq(amountIn, 100e18, "BonusOut exactOut fulfillment");
        assertEq(amountOut, BONUS_OUT_FULL);
    }

    function test_FulfillBonus_Fulfillment_OverAsk_AllBranches() public {
        ISwapVM.Order memory order = _bonusInOrder(INCENTIVE);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 120e18, _makeTakerData(order, true, true));
        assertEq(amountIn, 90e18, "BonusIn exactIn over-ask");
        assertEq(amountOut, 200e18);

        order = _bonusInOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 300e18, _makeTakerData(order, false, true));
        assertEq(amountIn, 90e18, "BonusIn exactOut over-ask");
        assertEq(amountOut, 200e18);

        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 150e18, _makeTakerData(order, true, true));
        assertEq(amountIn, 100e18, "BonusOut exactIn over-ask");
        assertEq(amountOut, BONUS_OUT_FULL);

        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 300e18, _makeTakerData(order, false, true));
        assertEq(amountIn, 100e18, "BonusOut exactOut over-ask");
        assertEq(amountOut, BONUS_OUT_FULL);
    }

    /// @dev The two variants express the same rate improvement on opposite axes
    function test_FulfillBonus_Variants_RateEquivalence() public {
        ISwapVM.Order memory orderIn = _bonusInOrder(INCENTIVE);
        (uint256 inIn, uint256 outIn,) = swapVM.swap(orderIn, 200e18, _makeTakerData(orderIn, false, false));

        ISwapVM.Order memory orderOut = _bonusOutOrder(INCENTIVE);
        (uint256 inOut, uint256 outOut,) = swapVM.swap(orderOut, 100e18, _makeTakerData(orderOut, true, false));

        // rate 200/90 == 222.22/100 up to rounding on the gross-up
        assertApproxEqRel(outIn * 1e18 / inIn, outOut * 1e18 / inOut, 1e6, "Both variants improve the rate identically");
    }

    function test_FulfillBonus_BonusOut_LargeIncentive_NoUnderflow() public {
        ISwapVM.Order memory order = _bonusOutOrder(0.6e7); // 60% incentive

        (, uint256 amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));

        assertEq(amountOut, 500e18, "Gross-up above 50% incentive works: 200e18 / (1 - 0.6)");
    }

    // === Partial fills settle at the plain rate in every branch ===

    function test_FulfillBonus_PartialFill_PlainRate_AllBranches() public {
        // Half fill exactIn and exactOut settle the identical plain-rate pair on both variants
        ISwapVM.Order memory order = _bonusInOrder(INCENTIVE);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 50e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18, "BonusIn exactIn partial");

        order = _bonusInOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 50e18, "BonusIn exactOut partial");
        assertEq(amountOut, 100e18);

        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 50e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18, "BonusOut exactIn partial");

        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 50e18, "BonusOut exactOut partial");
        assertEq(amountOut, 100e18);
    }

    // === Fulfillment boundary: one wei below stays plain, at or above earns the bonus ===

    function test_FulfillBonus_NoBonus_JustBelowFulfillment() public {
        // BonusIn exactIn: one wei below the discounted balance is a plain partial fill
        ISwapVM.Order memory order = _bonusInOrder(INCENTIVE);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 90e18 - 1, _makeTakerData(order, true, false));
        assertEq(amountIn, 90e18 - 1);
        assertEq(amountOut, 180e18 - 2, "BonusIn exactIn below boundary");

        // BonusIn exactOut: one wei below the full output pays the plain rate, more than fulfillment
        order = _bonusInOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 200e18 - 1, _makeTakerData(order, false, false));
        assertEq(amountIn, 100e18, "BonusIn exactOut below boundary");
        assertEq(amountOut, 200e18 - 1);

        // BonusOut exactIn: one wei below the input balance is a plain partial fill
        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, 100e18 - 1, _makeTakerData(order, true, false));
        assertEq(amountIn, 100e18 - 1);
        assertEq(amountOut, 200e18 - 2, "BonusOut exactIn below boundary");

        // BonusOut exactOut: one wei below the grossed-up ask fulfills at the plain balance
        order = _bonusOutOrder(INCENTIVE);
        (amountIn, amountOut,) = swapVM.swap(order, BONUS_OUT_FULL - 1, _makeTakerData(order, false, true));
        assertEq(amountIn, 100e18, "BonusOut exactOut below boundary");
        assertEq(amountOut, 200e18);
    }

    /// @dev BonusIn: any exact-in ask at or above the discounted balance is a fulfillment ask
    function test_FulfillBonus_BonusIn_ExactIn_AskAboveFulfillment_SettlesFulfillment() public {
        ISwapVM.Order memory order = _bonusInOrder(INCENTIVE);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 95e18, _makeTakerData(order, true, true));

        assertEq(amountIn, 90e18, "Ask clamps to the discounted balanceIn");
        assertEq(amountOut, 200e18);
    }

    /// @dev BonusOut: exact-out asks between the plain and grossed-up balance fulfill at the plain rate
    function test_FulfillBonus_BonusOut_ExactOut_AskBelowGrossUp_SettlesPlain() public {
        ISwapVM.Order memory order = _bonusOutOrder(INCENTIVE);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 210e18, _makeTakerData(order, false, true));

        assertEq(amountIn, 100e18, "Plain balance clamps the fill, maker keeps the bonus");
        assertEq(amountOut, 200e18);
    }

    // === Exact-in and exact-out settle on the same curve for any ask ===

    function testFuzz_BonusIn_ExactModesConsistent(uint256 ask, uint24 incentiveBps) public {
        incentiveBps = uint24(bound(incentiveBps, 0, 0.99e7));
        ask = bound(ask, 1, 300e18);

        ISwapVM.Order memory order = _bonusInOrder(incentiveBps);
        (uint256 in1, uint256 out1,) = swapVM.swap(order, ask, _makeTakerData(order, true, true));
        (uint256 in2, uint256 out2,) = swapVM.swap(order, out1, _makeTakerData(order, false, true));

        assertEq(in2, in1, "Exact-out must settle on the exact-in curve");
        assertEq(out2, out1);
    }

    function testFuzz_BonusOut_ExactModesConsistent(uint256 ask, uint24 incentiveBps) public {
        incentiveBps = uint24(bound(incentiveBps, 0, 0.99e7));
        ask = bound(ask, 1, 300e18);

        ISwapVM.Order memory order = _bonusOutOrder(incentiveBps);
        (uint256 in1, uint256 out1,) = swapVM.swap(order, ask, _makeTakerData(order, true, true));
        (uint256 in2, uint256 out2,) = swapVM.swap(order, out1, _makeTakerData(order, false, true));

        assertEq(in2, in1, "Exact-out must settle on the exact-in curve");
        assertEq(out2, out1);
    }

    // === Fulfill matrix: every variant x exact-in/out combination with invalidators ===

    /// @dev For each combination a partial fill at the plain rate is followed by an over-asked
    ///   fulfill of the remainder at the incentivized rate. The fulfill must fully consume the
    ///   invalidator-tracked axis and must not make splitting cheaper than a single fulfillment.
    function test_FulfillBonus_Fulfill_BonusIn_ExactIn() public { _checkFulfill(true, true); }
    function test_FulfillBonus_Fulfill_BonusIn_ExactOut() public { _checkFulfill(true, false); }
    function test_FulfillBonus_Fulfill_BonusOut_ExactIn() public { _checkFulfill(false, true); }
    function test_FulfillBonus_Fulfill_BonusOut_ExactOut() public { _checkFulfill(false, false); }

    function _checkFulfill(bool isBalanceIn, bool isExactIn) internal {
        // Canonical pairing: the bonus scales the axis opposite to the invalidator
        bytes memory program;
        if (isBalanceIn) {
            program = bytes.concat(
                StaticBalances.build(100e18, 200e18),
                InvalidateTokenOut.build(),
                FulfillBonusBalanceIn.build(INCENTIVE),
                LimitSwap.build(address(tokenA), address(tokenB))
            );
        } else {
            program = bytes.concat(
                StaticBalances.build(100e18, 200e18),
                InvalidateTokenIn.build(),
                FulfillBonusBalanceOut.build(INCENTIVE),
                LimitSwap.build(address(tokenA), address(tokenB))
            );
        }
        ISwapVM.Order memory order = _createOrder(program);
        bytes memory takerData = _makeTakerData(order, isExactIn, true);

        // Partial fill: a quarter of the ask axis at the plain rate
        (uint256 in1, uint256 out1,) = swapVM.swap(order, isExactIn ? 25e18 : 50e18, takerData);
        assertEq(in1, 25e18, "Partial fill at the plain rate");
        assertEq(out1, 50e18);

        // Fulfill: over-ask the remainder, priced at the full-incentive rate
        (uint256 in2, uint256 out2,) = swapVM.swap(order, isExactIn ? 100e18 : 300e18, takerData);

        if (isBalanceIn) {
            assertEq(in2, 67.5e18, "Fulfill pays the discounted remainder");
            assertEq(out2, 150e18);
            assertEq(out1 + out2, 200e18, "Output axis fully fulfilled");
            assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 200e18);
            // Split total 92.5e18 > 90e18 single fulfillment: no advantage in splitting
            assertGt(in1 + in2, 90e18, "Splitting must not beat a single fulfillment");
        } else {
            assertEq(in2, 75e18, "Fulfill pays the plain remainder");
            assertEq(out2, 166666666666666666666, "Fulfill receives the grossed-up remainder");
            assertEq(in1 + in2, 100e18, "Input axis fully fulfilled");
            assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(order), address(tokenA)), 100e18);
            // Split total 216.66e18 < 222.22e18 single fulfillment: no advantage in splitting
            assertLt(out1 + out2, BONUS_OUT_FULL, "Splitting must not beat a single fulfillment");
        }

        // The fulfill is priced at the full-incentive rate: (200 / 100) / (1 - 10%) = 2.2222
        uint256 fullBonusRate = uint256(200e18) * 1e18 / 90e18;
        assertApproxEqRel(out2 * 1e18 / in2, fullBonusRate, 1e9, "Fulfill priced at the full-incentive rate");

        // And strictly better than the plain-rate partial fill
        assertGt(out2 * in1, out1 * in2, "Fulfill rate must beat the partial-fill rate");
    }

    // === Build validation ===

    function buildBonusInExternal(uint24 incentiveBps) external pure returns (bytes memory) {
        return FulfillBonusBalanceIn.build(incentiveBps);
    }

    function buildBonusOutExternal(uint24 incentiveBps) external pure returns (bytes memory) {
        return FulfillBonusBalanceOut.build(incentiveBps);
    }

    function test_FulfillBonus_Build_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(FulfillBonusBalanceIn.FulfillBonusIncentiveOutOfRange.selector, uint24(1e7)));
        this.buildBonusInExternal(1e7);

        vm.expectRevert(abi.encodeWithSelector(FulfillBonusBalanceOut.FulfillBonusIncentiveOutOfRange.selector, uint24(1e7)));
        this.buildBonusOutExternal(1e7);
    }

    // === Helpers ===

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn, bool allowPartialFill) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: allowPartialFill,
            threshold: "",
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
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
