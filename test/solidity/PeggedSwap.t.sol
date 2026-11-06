// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test, stdError } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { Opcode } from "../../contracts/libs/OpcodeList.sol";
import { DynamicBalances, StaticBalances } from "../../contracts/instructions/Balances.sol";
import { PeggedSwap } from "../../contracts/instructions/PeggedSwap.sol";
import { FeeFlatIn, FeeFlatOut } from "../../contracts/instructions/FeeFlat.sol";
import { TokenMockDecimals } from "./mocks/TokenMockDecimals.sol";

contract PeggedSwapBuilder {
    function build(uint144 anchorA, uint144 anchorB, uint104 width) external pure returns (bytes memory) {
        return PeggedSwap.build(anchorA, anchorB, width);
    }

    function parse(bytes calldata program) external pure returns (uint144 anchorA, uint144 anchorB, uint104 width) {
        return PeggedSwap.parse(program[2:]);
    }
}

contract PeggedSwapTest is Test {
    using Math for uint256;

    uint256 private constant MAKER_PK = 0x1234;
    uint104 private constant WIDTH = 0.8e27;
    uint104 private constant TIGHT_WIDTH = 100e27;
    uint256 private constant ONEx2 = 1e54;
    // Fuzz anchors span 6-decimal to 18-decimal million-token pools; above ~1e27 the curve loses wei precision
    uint256 private constant MIN_ANCHOR = 1e6;
    uint256 private constant MAX_ANCHOR = 1e24;

    SwapVMRouter private swapVM;
    TraitsHelper private orders;
    TokenMock private tokenA;
    TokenMock private tokenB;
    address private maker;
    address private taker;

    struct Pool {
        address tokenA;
        address tokenB;
        uint256 balanceA;
        uint256 balanceB;
        uint144 anchorA;
        uint144 anchorB;
        uint104 width;
        uint24 feeOutBps;
    }

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        taker = makeAddr("taker");
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        _fundAndApprove(tokenA, 1e30);
        _fundAndApprove(tokenB, 1e30);
    }

    function test_PeggedSwap_StandardPeg_ExactInBothDirections() public view {
        ISwapVM.Order memory order = _standardOrder(0);
        uint256 amountIn = 100e18;

        (uint256 amountInAToB, uint256 amountOutAToB) = _quote(order, amountIn, true, true, false);
        (uint256 amountInBToA, uint256 amountOutBToA) = _quote(order, amountIn, true, false, false);

        assertEq(amountInAToB, amountIn);
        assertEq(amountInBToA, amountIn);
        assertLe(amountOutAToB, amountIn);
        assertLe(amountOutBToA, amountIn);
        assertGe(amountOutAToB, amountIn * 99 / 100);
        assertGe(amountOutBToA, amountIn * 99 / 100);
    }

    function test_PeggedSwap_StandardPeg_ExactOutBothDirections() public view {
        ISwapVM.Order memory order = _standardOrder(0);
        uint256 amountOut = 100e18;

        (uint256 amountInAToB, uint256 amountOutAToB) = _quote(order, amountOut, false, true, false);
        (uint256 amountInBToA, uint256 amountOutBToA) = _quote(order, amountOut, false, false, false);

        assertEq(amountOutAToB, amountOut);
        assertEq(amountOutBToA, amountOut);
        assertGe(amountInAToB, amountOut);
        assertGe(amountInBToA, amountOut);
        assertLe(amountInAToB, amountOut * 101 / 100);
        assertLe(amountInBToA, amountOut * 101 / 100);
    }

    function test_PeggedSwap_StandardPeg_QuoteMatchesSwap() public {
        ISwapVM.Order memory order = _standardOrder(0);
        (uint256 quotedIn, uint256 quotedOut) = _quote(order, 100e18, true, true, false);
        (uint256 swappedIn, uint256 swappedOut) = _swap(order, 100e18, true, true, false);

        assertEq(swappedIn, quotedIn);
        assertEq(swappedOut, quotedOut);
    }

    function test_PeggedSwap_RatedPeg_ExactInBothDirections() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 eurcIn, uint256 usdcOut) = _quote(order, 100e6, true, eurcToUsdc, false);
        (uint256 usdcIn, uint256 eurcOut) = _quote(order, 112e9, true, !eurcToUsdc, false);

        assertEq(eurcIn, 100e6);
        assertEq(usdcIn, 112e9);
        _assertExactInNearRate(usdcOut, 112e9);
        _assertExactInNearRate(eurcOut, 100e6);
    }

    function test_PeggedSwap_RatedPeg_ExactOutBothDirections() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 eurcIn, uint256 usdcOut) = _quote(order, 112e9, false, eurcToUsdc, false);
        (uint256 usdcIn, uint256 eurcOut) = _quote(order, 100e6, false, !eurcToUsdc, false);

        assertEq(usdcOut, 112e9);
        assertEq(eurcOut, 100e6);
        _assertExactOutNearRate(eurcIn, 100e6);
        _assertExactOutNearRate(usdcIn, 112e9);
    }

    function test_PeggedSwap_RatedPeg_QuoteMatchesSwap() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 quotedIn, uint256 quotedOut) = _quote(order, 100e6, true, eurcToUsdc, false);
        (uint256 swappedIn, uint256 swappedOut) = _swap(order, 100e6, true, eurcToUsdc, false);

        assertEq(swappedIn, quotedIn);
        assertEq(swappedOut, quotedOut);
    }

    function test_PeggedSwap_ExactOutPositiveOutputAlwaysChargesInput() public view {
        ISwapVM.Order memory order = _standardOrder(0);

        (uint256 amountIn, uint256 amountOut) = _quote(order, 1, false, true, false);

        assertEq(amountOut, 1);
        assertGt(amountIn, 0);
    }

    function testFuzz_PeggedSwap_FeeGrowthMaintainsMonotonicity(
        uint144 anchor,
        uint16 growth,
        uint104 width,
        uint256 amount,
        bool isAToB
    ) public view {
        anchor = uint144(bound(anchor, 1e18, 1e30));
        growth = uint16(bound(growth, 1, 1_000));
        width = uint104(bound(width, 0.25e27, 5_000e27));
        uint256 balance = uint256(anchor) * growth;
        amount = bound(amount, 1e6, balance / 10);

        Pool memory pool = _standardPool(0);
        pool.balanceA = balance;
        pool.balanceB = balance;
        pool.anchorA = anchor;
        pool.anchorB = anchor;
        pool.width = width;

        ISwapVM.Order memory order = _order(pool);
        (, uint256 amountOut) = _quote(order, amount, true, isAToB, false);
        (, uint256 amountOutPlusOne) = _quote(order, amount + 1, true, isAToB, false);
        (uint256 amountIn,) = _quote(order, amount, false, isAToB, false);
        (uint256 amountInPlusOne,) = _quote(order, amount + 1, false, isAToB, false);

        assertLe(amountOut, amountOutPlusOne);
        assertLe(amountIn, amountInPlusOne);
    }

    function test_PeggedSwap_ExactInPartialFillDrainsOutputReserve() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1_000e18;
        pool.balanceB = 1_000e18;
        pool.anchorA = 1_000e18;
        pool.anchorB = 1_000e18;
        ISwapVM.Order memory order = _order(pool);
        uint256 requestedIn = 100_000e18;

        (uint256 amountIn, uint256 amountOut) = _swap(order, requestedIn, true, true, true);

        assertLt(amountIn, requestedIn);
        assertEq(amountOut, pool.balanceB);
    }

    function test_PeggedSwap_Revert_ExactInRoundingUnderflowReturnsZeroOutput() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1e27 - 1;
        pool.balanceB = 1e27 - 1;
        pool.anchorA = 1e27;
        pool.anchorB = 1e27;
        ISwapVM.Order memory order = _order(pool);
        bytes memory takerData = _takerData(order, true, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        quoter.quote(order, 1, takerData);
    }

    function test_PeggedSwap_ExactOutPartialFillCapsOutputAtReserve() public view {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1_000e18;
        pool.balanceB = 1_000e18;
        pool.anchorA = 1_000e18;
        pool.anchorB = 1_000e18;

        (uint256 amountIn, uint256 amountOut) = _quote(_order(pool), 100_000e18, false, true, true);

        assertGt(amountIn, 0);
        assertEq(amountOut, pool.balanceB);
    }

    function test_PeggedSwap_FeeOutReducesOutput() public view {
        ISwapVM.Order memory orderWithoutFee = _standardOrder(0);
        ISwapVM.Order memory orderWithFee = _standardOrder(uint24(FeeFlatOut.BPS >> 2));

        (, uint256 amountOutWithoutFee) = _quote(orderWithoutFee, 100e18, true, true, false);
        (, uint256 amountOutWithFee) = _quote(orderWithFee, 100e18, true, true, false);

        assertLt(amountOutWithFee, amountOutWithoutFee);
        assertLe(amountOutWithFee, amountOutWithoutFee * 3 / 4);
    }

    function test_PeggedSwap_WidthControlsSlippage() public view {
        Pool memory curvedPool = _standardPool(0);
        curvedPool.width = 0.25e27;
        Pool memory tightPool = _standardPool(0);
        tightPool.width = 5_000e27;

        (, uint256 curvedOut) = _quote(_order(curvedPool), 1_000e18, true, true, false);
        (, uint256 tightOut) = _quote(_order(tightPool), 1_000e18, true, true, false);

        assertGt(tightOut, curvedOut);
        assertLe(tightOut, 1_000e18);
        assertGe(tightOut, 999.9e18);
    }

    function test_PeggedSwap_Revert_ContextOverflow() public {
        bytes memory program = bytes.concat(
            StaticBalances.build(uint256(1) << 144, 10_000e18),
            PeggedSwap.build(10_000e18, 10_000e18, WIDTH)
        );
        ISwapVM.Order memory order = _order(address(tokenA), address(tokenB), program);
        bytes memory takerData = _takerData(order, true, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, 1e18, takerData);
    }

    function test_PeggedSwap_Revert_ContributionOverflow() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1e30;
        pool.balanceB = 1e30;
        pool.anchorA = 1e18;
        pool.anchorB = 1e18;
        pool.width = 5_000e27;
        ISwapVM.Order memory order = _order(pool);
        bytes memory takerData = _takerData(order, false, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, 1, takerData);
    }

    function test_PeggedSwap_BuildValidation() public {
        PeggedSwapBuilder builder = new PeggedSwapBuilder();

        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidAnchors.selector, 0, 1));
        builder.build(0, 1, WIDTH);

        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidAnchors.selector, 1, 0));
        builder.build(1, 0, WIDTH);

        uint104 invalidWidth = uint104(0.25e27 - 1);
        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidWidth.selector, invalidWidth));
        builder.build(1, 1, invalidWidth);

        invalidWidth = uint104(5_000e27 + 1);
        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidWidth.selector, invalidWidth));
        builder.build(1, 1, invalidWidth);

        assertEq(builder.build(1, 1, 0.25e27).length, PeggedSwap.sizeOf());
        assertEq(builder.build(1, 1, 5_000e27).length, PeggedSwap.sizeOf());
    }

    function test_PeggedSwap_BuildParseRoundTrip() public {
        PeggedSwapBuilder builder = new PeggedSwapBuilder();
        uint144 maxAnchor = type(uint144).max;

        bytes memory program = builder.build(maxAnchor, 1, 5_000e27);
        assertEq(program.length, PeggedSwap.sizeOf());
        assertEq(uint8(program[0]), uint8(Opcode.PeggedSwap));
        assertEq(uint8(program[1]), 18 + 18 + 13);

        (uint144 anchorA, uint144 anchorB, uint104 width) = builder.parse(program);
        assertEq(anchorA, maxAnchor);
        assertEq(anchorB, 1);
        assertEq(width, 5_000e27);

        (anchorA, anchorB, width) = builder.parse(builder.build(1, maxAnchor, 0.25e27));
        assertEq(anchorA, 1);
        assertEq(anchorB, maxAnchor);
        assertEq(width, 0.25e27);
    }

    // ---- Branches ----

    function test_PeggedSwap_ExactIn_DrainBoundaryBranches() public {
        Pool memory pool = _standardPool(0);
        ISwapVM.Order memory order = _order(pool);
        uint256 drainIn = _drainIn(order, pool, true);

        // Requesting exactly the drain amount lands on the partial branch and is still a full fill
        (uint256 amountIn, uint256 amountOut) = _quote(order, drainIn, true, true, false);
        assertEq(amountIn, drainIn);
        assertEq(amountOut, pool.balanceB);

        // One wei less stays on the regular branch and leaves dust in the reserve
        (amountIn, amountOut) = _quote(order, drainIn - 1, true, true, false);
        assertEq(amountIn, drainIn - 1);
        assertLt(amountOut, pool.balanceB);

        // Anything above is clamped down to the drain amount, so a fill-or-kill taker reverts
        bytes memory takerData = _takerData(order, true, true, false);
        ISwapVM quoter = swapVM.asView();
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector, drainIn + 1, drainIn));
        quoter.quote(order, drainIn + 1, takerData);

        // Exact-out of the whole reserve charges exactly the drain amount
        (amountIn, amountOut) = _quote(order, pool.balanceB, false, true, false);
        assertEq(amountIn, drainIn);
        assertEq(amountOut, pool.balanceB);
    }

    function test_PeggedSwap_FiniteReserves_DrainMatchesClosedForm() public view {
        // Balances at anchors: `sqrt(x) + width * x = 2 + 2 * width` solved for `x`, minus the anchor already in the pool
        uint104[5] memory widths = [uint104(0.25e27), 0.8e27, 1e27, 100e27, 5_000e27];
        uint256[5] memory drainPerAnchor = [uint256(2.033370453e18), 1.516905310e18, 1.438447187e18, 1.005837242e18, 1.000117149e18];

        for (uint256 i = 0; i < widths.length; i++) {
            Pool memory pool = _standardPool(0);
            pool.width = widths[i];
            uint256 drainIn = _drainIn(_order(pool), pool, true);
            assertApproxEqRel(drainIn, uint256(pool.anchorA) * drainPerAnchor[i] / 1e18, 1e10);
        }
    }

    function test_PeggedSwap_Revert_ExactOutAboveReserveWithoutPartialFill() public {
        ISwapVM.Order memory order = _standardOrder(0);
        bytes memory takerData = _takerData(order, false, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector, 100_000e18, 10_000e18));
        quoter.quote(order, 100_000e18, takerData);
    }

    function test_PeggedSwap_Revert_ContextOverflow_AmountIn() public {
        ISwapVM.Order memory order = _standardOrder(0);
        bytes memory takerData = _takerData(order, true, true, true);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, uint256(1) << 144, takerData);
    }

    function test_PeggedSwap_Revert_ContextOverflow_AmountOutEvenWithPartialFill() public {
        // The register check runs before the clamp to balanceOut, so "max"-style exact-out requests revert
        ISwapVM.Order memory order = _standardOrder(0);
        bytes memory takerData = _takerData(order, false, true, true);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, uint256(1) << 144, takerData);

        (uint256 amountIn, uint256 amountOut) = _quote(order, (uint256(1) << 144) - 1, false, true, true);
        assertEq(amountOut, 10_000e18);
        assertGt(amountIn, 0);
    }

    function test_PeggedSwap_Revert_ExactInHugeAmountOverflowsBeforeClamp() public {
        // The requested amount enters `balanceIn + amountIn` before any clamp, so for small anchors
        // amounts above ~1e23 * anchorIn overflow the 1e54-scaled sqrt argument instead of partially filling
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1e12;
        pool.balanceB = 1e12;
        pool.anchorA = 1e12;
        pool.anchorB = 1e12;
        ISwapVM.Order memory order = _order(pool);

        (uint256 amountIn, uint256 amountOut) = _quote(order, 1e35, true, true, true);
        assertEq(amountOut, pool.balanceB);
        assertLt(amountIn, 1e35);

        bytes memory takerData = _takerData(order, true, true, true);
        ISwapVM quoter = swapVM.asView();
        vm.expectRevert(stdError.arithmeticError);
        quoter.quote(order, 1e36, takerData);
    }

    function test_PeggedSwap_Revert_AnchorRatioOverflowPanics() public {
        // balance / anchor above ~1e23 overflows the sqrt scaling before `solve` can raise the custom error
        bytes memory program = bytes.concat(
            StaticBalances.build(1e30, 1e30),
            PeggedSwap.build(1, 1, WIDTH)
        );
        ISwapVM.Order memory order = _order(address(tokenA), address(tokenB), program);
        bytes memory takerData = _takerData(order, false, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(stdError.arithmeticError);
        quoter.quote(order, 1, takerData);
    }

    // ---- Configurations ----

    function test_PeggedSwap_AsymmetricAnchors_RateFollowsAnchorRatio() public view {
        Pool memory pool = _standardPool(0);
        pool.balanceB = 20_000e18;
        pool.anchorB = 20_000e18;
        pool.width = TIGHT_WIDTH;
        ISwapVM.Order memory order = _order(pool);

        (, uint256 outAToB) = _quote(order, 1e18, true, true, false);
        (, uint256 outBToA) = _quote(order, 2e18, true, false, false);
        (uint256 inAToB,) = _quote(order, 2e18, false, true, false);
        (uint256 inBToA,) = _quote(order, 1e18, false, false, false);

        _assertExactInNearRate(outAToB, 2e18);
        _assertExactInNearRate(outBToA, 1e18);
        _assertExactOutNearRate(inAToB, 1e18);
        _assertExactOutNearRate(inBToA, 2e18);
    }

    function test_PeggedSwap_SkewedBalances_PriceMovesAgainstAbundantSide() public view {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 20_000e18; // 2x anchor
        pool.balanceB = 5_000e18; // 0.5x anchor
        ISwapVM.Order memory order = _order(pool);

        (, uint256 outSellingAbundant) = _quote(order, 100e18, true, true, false);
        (, uint256 outSellingScarce) = _quote(order, 100e18, true, false, false);

        assertLt(outSellingAbundant, 100e18);
        assertGt(outSellingScarce, 100e18);
        // Reference values from an exact integer model of the curve
        assertApproxEqRel(outSellingAbundant, 76373778005093701894, 1e12);
        assertApproxEqRel(outSellingScarce, 130280368412252574212, 1e12);
    }

    function test_PeggedSwap_FeeGrowth_ReducesSlippage() public view {
        uint16[3] memory growths = [uint16(1), 10, 100];
        uint256 prevIn;
        uint256 prevOut;

        for (uint256 i = 0; i < growths.length; i++) {
            Pool memory pool = _standardPool(0);
            pool.balanceA = uint256(pool.anchorA) * growths[i];
            pool.balanceB = uint256(pool.anchorB) * growths[i];
            (uint256 amountIn, uint256 amountOut) = _quote(_order(pool), pool.balanceA / 100, true, true, false);

            assertLt(amountOut, amountIn);
            // Same 1% of the pool gets a better rate as balances outgrow the anchors
            if (i > 0) assertGt(amountOut * prevIn, prevOut * amountIn);
            (prevIn, prevOut) = (amountIn, amountOut);
        }
    }

    function test_PeggedSwap_DynamicBalances_CurveStateAdvancesWithSwaps() public {
        Pool memory pool = _standardPool(0);
        ISwapVM.Order memory order = _order(pool);
        bytes32 orderHash = swapVM.hash(order);

        (uint256 in1, uint256 out1) = _swap(order, 100e18, true, true, false);
        (uint256 in2, uint256 out2) = _swap(order, 100e18, true, true, false);
        assertLt(out2, out1);
        assertEq(swapVM.balance(orderHash, address(tokenA)), pool.balanceA + in1 + in2);
        assertEq(swapVM.balance(orderHash, address(tokenB)), pool.balanceB - out1 - out2);

        // The side that became scarce now sells above 1:1
        (, uint256 outBack) = _quote(order, 100e18, true, false, false);
        assertGt(outBack, 100e18);
    }

    function test_PeggedSwap_FeeIn_ExactOutGrossesUpInput() public view {
        uint24 feeBps = uint24(FeeFlatIn.BPS / 1000); // 0.1%
        bytes memory program = bytes.concat(
            DynamicBalances.build(10_000e18, 10_000e18),
            FeeFlatIn.build(feeBps),
            PeggedSwap.build(10_000e18, 10_000e18, WIDTH)
        );
        ISwapVM.Order memory orderWithFee = _order(address(tokenA), address(tokenB), program);
        ISwapVM.Order memory orderWithoutFee = _standardOrder(0);

        (uint256 inWithFee, uint256 outWithFee) = _quote(orderWithFee, 100e18, false, true, false);
        (uint256 inWithoutFee,) = _quote(orderWithoutFee, 100e18, false, true, false);
        assertEq(outWithFee, 100e18);
        assertEq(inWithFee, inWithoutFee + (inWithoutFee * feeBps).ceilDiv(FeeFlatIn.BPS - feeBps));

        (, uint256 outExactInWithFee) = _quote(orderWithFee, 100e18, true, true, false);
        (, uint256 outExactInWithoutFee) = _quote(orderWithoutFee, 100e18, true, true, false);
        assertLt(outExactInWithFee, outExactInWithoutFee);
    }

    function test_PeggedSwap_DocsExample_UsdcDaiPeg() public {
        // docs/DESCRIPTION.md "Pegged" program: raw anchors in each token's own decimals
        TokenMock usdc = new TokenMockDecimals("USDC", "USDC", 6);
        TokenMock dai = new TokenMockDecimals("DAI", "DAI", 18);
        _fundAndApprove(usdc, 1e15);
        _fundAndApprove(dai, 1e27);
        bool usdcIsA = address(usdc) < address(dai);

        (uint144 usdcAnchor, uint144 daiAnchor) = (1_000_000e6, 1_000_000e18);
        bytes memory program = bytes.concat(
            DynamicBalances.build(usdcIsA ? usdcAnchor : daiAnchor, usdcIsA ? daiAnchor : usdcAnchor),
            FeeFlatIn.build(0.0001e7), // 0.01%
            PeggedSwap.build(usdcIsA ? usdcAnchor : daiAnchor, usdcIsA ? daiAnchor : usdcAnchor, TIGHT_WIDTH)
        );
        ISwapVM.Order memory order = _order(
            usdcIsA ? address(usdc) : address(dai),
            usdcIsA ? address(dai) : address(usdc),
            program
        );

        // 0.01% fee plus ~0.00025% curve slippage on a 0.1%-of-pool trade
        (uint256 usdcIn, uint256 daiOut) = _swap(order, 1_000e6, true, usdcIsA, false);
        assertEq(usdcIn, 1_000e6);
        assertLt(daiOut, 999.9e18);
        assertGt(daiOut, 999.89e18);

        (uint256 daiIn, uint256 usdcOut) = _swap(order, 1_000e18, true, !usdcIsA, false);
        assertEq(daiIn, 1_000e18);
        assertLt(usdcOut, 1_000e6);
        assertApproxEqRel(usdcOut, 999.9e6, 1e13);

        (uint256 usdcInExactOut, uint256 daiOutExactOut) = _quote(order, 1_000e18, false, usdcIsA, false);
        assertEq(daiOutExactOut, 1_000e18);
        assertGt(usdcInExactOut, 1_000e6);
        assertApproxEqRel(usdcInExactOut, 1_000.1e6, 1e13);
    }

    // ---- Properties over skewed pools with independent anchors ----

    function testFuzz_PeggedSwap_RoundTrip_ExactInAndExactOutAgree(
        uint144 anchorA,
        uint144 anchorB,
        uint8 growthA,
        uint8 growthB,
        uint104 width,
        uint256 amountIn,
        uint256 amountOut,
        bool isAToB
    ) public view {
        Pool memory pool = _fuzzPool(anchorA, anchorB, growthA, growthB, width);
        ISwapVM.Order memory order = _order(pool);
        (amountIn, amountOut) = _fuzzAmounts(pool, isAToB, amountIn, amountOut);

        // Buying back what exact-in paid out never costs more than the original input (1 wei of stacked rounding)
        (uint256 inA, uint256 outA) = _quote(order, amountIn, true, isAToB, false);
        (uint256 inB, uint256 outB) = _quote(order, outA, false, isAToB, false);
        assertEq(inA, amountIn);
        assertEq(outB, outA);
        assertLe(inB, amountIn + 1);

        // Spending what exact-out charged returns the requested output minus at most 1 wei
        (uint256 inC, uint256 outC) = _quote(order, amountOut, false, isAToB, false);
        (uint256 inD, uint256 outD) = _quote(order, inC, true, isAToB, false);
        assertEq(outC, amountOut);
        assertEq(inD, inC);
        assertGe(outD + 1, amountOut);
    }

    function testFuzz_PeggedSwap_InvariantNeverDecreases_RoundingTight(
        uint144 anchorA,
        uint144 anchorB,
        uint8 growthA,
        uint8 growthB,
        uint104 width,
        uint256 amountIn,
        uint256 amountOut,
        bool isAToB
    ) public view {
        Pool memory pool = _fuzzPool(anchorA, anchorB, growthA, growthB, width);
        ISwapVM.Order memory order = _order(pool);
        (amountIn, amountOut) = _fuzzAmounts(pool, isAToB, amountIn, amountOut);
        (uint256 balanceIn, uint256 balanceOut, uint256 anchorIn, uint256 anchorOut) = _sides(pool, isAToB);
        uint256 before = _liquidity(balanceIn, balanceOut, anchorIn, anchorOut, pool.width, false);

        // Curve value never drops (4 units of 1e-27 cover the floor rounding of the four terms),
        // yet handing the taker 2 more wei would break the invariant
        (, uint256 outA) = _quote(order, amountIn, true, isAToB, false);
        assertGe(_liquidity(balanceIn + amountIn, balanceOut - outA, anchorIn, anchorOut, pool.width, false) + 4, before);
        if (outA + 2 <= balanceOut) {
            assertLt(_liquidity(balanceIn + amountIn, balanceOut - outA - 2, anchorIn, anchorOut, pool.width, true), before);
        }

        (uint256 inC,) = _quote(order, amountOut, false, isAToB, false);
        assertGe(_liquidity(balanceIn + inC, balanceOut - amountOut, anchorIn, anchorOut, pool.width, false) + 4, before);
        if (inC >= 2) {
            assertLt(_liquidity(balanceIn + inC - 2, balanceOut - amountOut, anchorIn, anchorOut, pool.width, true), before);
        }
    }

    function testFuzz_PeggedSwap_SkewedPool_Monotonicity(
        uint144 anchorA,
        uint144 anchorB,
        uint8 growthA,
        uint8 growthB,
        uint104 width,
        uint256 amountIn,
        uint256 amountOut,
        bool isAToB
    ) public view {
        Pool memory pool = _fuzzPool(anchorA, anchorB, growthA, growthB, width);
        ISwapVM.Order memory order = _order(pool);
        (amountIn, amountOut) = _fuzzAmounts(pool, isAToB, amountIn, amountOut);

        (, uint256 out) = _quote(order, amountIn, true, isAToB, false);
        (, uint256 outPlusOne) = _quote(order, amountIn + 1, true, isAToB, false);
        (uint256 in_,) = _quote(order, amountOut, false, isAToB, false);
        (uint256 inPlusOne,) = _quote(order, amountOut + 1, false, isAToB, false);

        assertLe(out, outPlusOne);
        assertLe(in_, inPlusOne);
    }

    function testFuzz_PeggedSwap_PartialFill_NeverExceedsRequestAndMatchesDrain(
        uint144 anchorA,
        uint144 anchorB,
        uint8 growthA,
        uint8 growthB,
        uint104 width,
        bool isAToB
    ) public view {
        Pool memory pool = _fuzzPool(anchorA, anchorB, growthA, growthB, width);
        ISwapVM.Order memory order = _order(pool);
        (, uint256 balanceOut, uint256 anchorIn,) = _sides(pool, isAToB);

        // 100 anchors of input is always beyond the finite reserve
        uint256 requestedIn = 100 * anchorIn;
        (uint256 drainIn, uint256 drainOut) = _quote(order, requestedIn, true, isAToB, true);
        assertLt(drainIn, requestedIn);
        assertEq(drainOut, balanceOut);

        // Exact-out of the whole reserve, clamped or not, charges the same amount
        (uint256 inFull, uint256 outFull) = _quote(order, balanceOut, false, isAToB, false);
        assertEq(inFull, drainIn);
        assertEq(outFull, balanceOut);
        (uint256 inClamped, uint256 outClamped) = _quote(order, 100 * balanceOut, false, isAToB, true);
        assertEq(inClamped, drainIn);
        assertEq(outClamped, balanceOut);
    }

    function testFuzz_PeggedSwap_ExactOutAlwaysChargesInput(
        uint144 anchorA,
        uint144 anchorB,
        uint8 growthA,
        uint8 growthB,
        uint104 width,
        uint256 amountOut,
        bool isAToB
    ) public view {
        Pool memory pool = _fuzzPool(anchorA, anchorB, growthA, growthB, width);
        (, uint256 balanceOut,,) = _sides(pool, isAToB);
        amountOut = bound(amountOut, 1, balanceOut);

        (uint256 amountIn, uint256 quotedOut) = _quote(_order(pool), amountOut, false, isAToB, false);

        assertEq(quotedOut, amountOut);
        assertGt(amountIn, 0);
    }

    function testFuzz_PeggedSwap_SymmetricPool_DirectionAgnostic(uint144 anchor, uint8 growth, uint104 width, uint256 amount) public view {
        Pool memory pool = _fuzzPool(anchor, anchor, growth, growth, width);
        ISwapVM.Order memory order = _order(pool);
        (uint256 amountIn, uint256 amountOut) = _fuzzAmounts(pool, true, amount, amount);

        (uint256 inAToB, uint256 outAToB) = _quote(order, amountIn, true, true, false);
        (uint256 inBToA, uint256 outBToA) = _quote(order, amountIn, true, false, false);
        assertEq(inAToB, inBToA);
        assertEq(outAToB, outBToA);

        (inAToB, outAToB) = _quote(order, amountOut, false, true, false);
        (inBToA, outBToA) = _quote(order, amountOut, false, false, false);
        assertEq(inAToB, inBToA);
        assertEq(outAToB, outBToA);
    }

    // ---- Helpers ----

    /// @dev Independent anchors, balances skewed 0.1x..10x of the anchors, any valid width
    function _fuzzPool(uint144 anchorA, uint144 anchorB, uint8 growthA, uint8 growthB, uint104 width) private view returns (Pool memory pool) {
        pool = _standardPool(0);
        pool.anchorA = uint144(bound(anchorA, MIN_ANCHOR, MAX_ANCHOR));
        pool.anchorB = uint144(bound(anchorB, MIN_ANCHOR, MAX_ANCHOR));
        pool.balanceA = uint256(pool.anchorA) * bound(growthA, 1, 100) / 10;
        pool.balanceB = uint256(pool.anchorB) * bound(growthB, 1, 100) / 10;
        pool.width = uint104(bound(width, 0.25e27, 5_000e27));
    }

    function _sides(Pool memory pool, bool isAToB) private pure returns (uint256 balanceIn, uint256 balanceOut, uint256 anchorIn, uint256 anchorOut) {
        return isAToB
            ? (pool.balanceA, pool.balanceB, pool.anchorA, pool.anchorB)
            : (pool.balanceB, pool.balanceA, pool.anchorB, pool.anchorA);
    }

    /// @dev Amounts that stay on the regular branch with a non-zero counterpart: at most 10% of the smaller
    ///   side measured in anchor units, at least 1000 wei of whichever side is coarser
    function _fuzzAmounts(Pool memory pool, bool isAToB, uint256 amountIn, uint256 amountOut) private pure returns (uint256, uint256) {
        (uint256 balanceIn, uint256 balanceOut, uint256 anchorIn, uint256 anchorOut) = _sides(pool, isAToB);
        amountIn = bound(amountIn, Math.max(1000, 1000 * anchorIn / anchorOut), Math.min(balanceIn, anchorIn * balanceOut / anchorOut) / 10);
        amountOut = bound(amountOut, Math.max(1000, 1000 * anchorOut / anchorIn), Math.min(balanceOut, anchorOut * balanceIn / anchorIn) / 10);
        return (amountIn, amountOut);
    }

    /// @dev Input that empties the output reserve, read back from a partial-fill quote
    function _drainIn(ISwapVM.Order memory order, Pool memory pool, bool isAToB) private view returns (uint256 drainIn) {
        (drainIn,) = _quote(order, 100 * uint256(isAToB ? pool.anchorA : pool.anchorB), true, isAToB, true);
    }

    /// @dev Curve value `sqrt(bIn/aIn) + sqrt(bOut/aOut) + width * (bIn/aIn + bOut/aOut)` in 1e27 units, each term rounded
    function _liquidity(uint256 balanceIn, uint256 balanceOut, uint256 anchorIn, uint256 anchorOut, uint256 width, bool roundUp) private pure returns (uint256) {
        return _contribution(balanceIn, anchorIn, width, roundUp) + _contribution(balanceOut, anchorOut, width, roundUp);
    }

    function _contribution(uint256 balance, uint256 anchor, uint256 width, bool roundUp) private pure returns (uint256) {
        Math.Rounding rounding = roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor;
        return ONEx2.mulDiv(balance, anchor, rounding).sqrt(rounding) + (width * balance).mulDiv(1, anchor, rounding);
    }

    function _standardOrder(uint24 feeOutBps) private view returns (ISwapVM.Order memory) {
        return _order(_standardPool(feeOutBps));
    }

    function _standardPool(uint24 feeOutBps) private view returns (Pool memory) {
        return Pool({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            balanceA: 10_000e18,
            balanceB: 10_000e18,
            anchorA: 10_000e18,
            anchorB: 10_000e18,
            width: WIDTH,
            feeOutBps: feeOutBps
        });
    }

    function _ratedOrder() private returns (ISwapVM.Order memory order, address eurc, address usdc) {
        TokenMock eurcToken = new TokenMockDecimals("EURC", "EURC", 6);
        TokenMock usdcToken = new TokenMockDecimals("USDC", "USDC", 9);
        eurc = address(eurcToken);
        usdc = address(usdcToken);
        _fundAndApprove(eurcToken, 1_000_000e6);
        _fundAndApprove(usdcToken, 1_120_000e9);

        bool eurcIsA = eurc < usdc;
        order = _order(Pool({
            tokenA: eurcIsA ? eurc : usdc,
            tokenB: eurcIsA ? usdc : eurc,
            balanceA: eurcIsA ? 10_000e6 : 11_200e9,
            balanceB: eurcIsA ? 11_200e9 : 10_000e6,
            anchorA: eurcIsA ? 10_000e6 : 11_200e9,
            anchorB: eurcIsA ? 11_200e9 : 10_000e6,
            width: TIGHT_WIDTH,
            feeOutBps: 0
        }));
    }

    function _order(Pool memory pool) private view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(
            DynamicBalances.build(pool.balanceA, pool.balanceB),
            pool.feeOutBps == 0 ? bytes("") : FeeFlatOut.build(pool.feeOutBps),
            PeggedSwap.build(pool.anchorA, pool.anchorB, pool.width)
        );
        return _order(pool.tokenA, pool.tokenB, program);
    }

    function _order(address tokenLt, address tokenGt, bytes memory program) private view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            receiver: address(0),
            tokenA: tokenLt,
            tokenB: tokenGt,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
            allowZeroAmountIn: false,
            program: program
        }));
    }

    function _quote(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private view returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = swapVM.asView().quote(
            order,
            amount,
            _takerData(order, isExactIn, isAToB, allowPartialFill)
        );
    }

    function _swap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private returns (uint256 amountIn, uint256 amountOut) {
        bytes memory takerData = _takerData(order, isExactIn, isAToB, allowPartialFill);
        vm.prank(taker);
        (amountIn, amountOut,) = swapVM.swap(order, amount, takerData);
    }

    function _takerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, orderHash);

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: allowPartialFill,
            usePermit2: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            signature: abi.encodePacked(r, s, v)
        }));
    }

    function _fundAndApprove(TokenMock token, uint256 amount) private {
        token.mint(maker, amount);
        token.mint(taker, amount);
        vm.prank(maker);
        token.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        token.approve(address(swapVM), type(uint256).max);
    }

    function _assertExactInNearRate(uint256 actualOut, uint256 idealOut) private pure {
        assertLe(actualOut, idealOut);
        assertGe(actualOut, idealOut * 999 / 1000);
    }

    function _assertExactOutNearRate(uint256 actualIn, uint256 idealIn) private pure {
        assertGe(actualIn, idealIn);
        assertLe(actualIn, idealIn * 1001 / 1000);
    }
}
