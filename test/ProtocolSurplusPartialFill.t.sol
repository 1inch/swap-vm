// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenIn, InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { PiecewiseLinearScaleBalanceIn } from "../src/instructions/PiecewiseLinearScale.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";
import { FeeMeta, FeeMetaLib } from "../src/libs/ProtocolFee.sol";
import { FeeBuilders } from "./utils/FeeBuilders.sol";

contract ProtocolSurplusPartialFillTest is Test {
    using Math for uint256;

    uint256 constant BPS = 1e7;

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient = makeAddr("feeRecipient");

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

    /// @dev Order: 100e18 in -> 200e18 out, maker estimates 80e18 total input, 10% surplus fee.
    ///   The maker's fixed axis is the output: InvalidateTokenOut precedes FeeProtocol and scales
    ///   the token-in estimate by the delivered output fraction.
    ///   Each fill of half the order must contribute half the estimate: surplus 10e18, fee 1e18 per fill,
    ///   regardless of being the first or the second fill and of over-asking.
    function test_SurplusIn_Multifill_ProRataEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            InvalidateTokenOut.build(),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 80e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _makeTakerData(order, true);

        // First fill: half the order
        uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
        uint256 makerBefore = tokenA.balanceOf(maker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 50e18, exactInData);

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18);
        // estimate share 40e18, realIn 50e18 -> surplus 10e18, fee 1e18
        assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1e18, "First fill surplus fee");
        assertEq(tokenA.balanceOf(maker) - makerBefore, 49e18, "Maker receives input minus surplus fee");

        // Second fill: over-ask partially fills the remaining half, same pro-rata surplus
        recipientBefore = tokenA.balanceOf(feeRecipient);
        makerBefore = tokenA.balanceOf(maker);
        (amountIn, amountOut,) = swapVM.swap(order, 80e18, exactInData);

        assertEq(amountIn, 50e18, "Over-ask should partially fill the remainder");
        assertEq(amountOut, 100e18);
        assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1e18, "Second fill surplus fee should stay pro-rata");
        assertEq(tokenA.balanceOf(maker) - makerBefore, 49e18, "Maker receives input minus surplus fee");

        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 200e18);
    }

    /// @dev Order: 100e18 in -> 200e18 out, maker estimates 240e18 total output, 10% surplus fee.
    ///   The maker's fixed axis is the input: InvalidateTokenIn precedes FeeProtocol and scales
    ///   the token-out estimate by the consumed input fraction.
    ///   Each fill of half the order compares against half the estimate: surplus 20e18, fee 2e18 per fill.
    function test_SurplusOut_Multifill_ProRataEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            InvalidateTokenIn.build(),
            FeeBuilders.protocolSurplusOut(0.1e7, feeRecipient, 240e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _makeTakerData(order, false);

        // First fill: half the order
        uint256 recipientBefore = tokenB.balanceOf(feeRecipient);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactOutData);

        assertEq(amountOut, 100e18);
        assertEq(amountIn, 50e18);
        // estimate share 120e18, realOut 100e18 -> surplus 20e18, fee 2e18 paid by maker
        assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, 2e18, "First fill surplus fee");

        // Second fill: over-ask partially fills the remaining half, same pro-rata surplus
        recipientBefore = tokenB.balanceOf(feeRecipient);
        (amountIn, amountOut,) = swapVM.swap(order, 150e18, exactOutData);

        assertEq(amountOut, 100e18, "Over-ask should partially fill the remainder");
        assertEq(amountIn, 50e18);
        assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, 2e18, "Second fill surplus fee should stay pro-rata");

        assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(order), address(tokenA)), 100e18);
    }

    function testFuzz_SurplusIn_Multifill(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 estimate,
        uint24 feeBps,
        uint24 surplusBps,
        uint256[3] memory asks
    ) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        estimate = bound(estimate, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, BPS - 1));
        surplusBps = uint24(bound(surplusBps, 1, BPS - 1));

        ISwapVM.Order memory order = _flatSurplusOrder(true, balanceIn, balanceOut, feeBps, surplusBps, estimate);
        bytes memory exactInData = _makeTakerData(order, true);

        uint256 filledOut;
        uint256 totalShares;
        for (uint256 i = 0; i < asks.length; i++) {
            uint256 remainingOut = balanceOut - filledOut;
            if (remainingOut == 0) break;

            // InvalidateTokenOut restores the remaining capacity, rounding the input side up
            uint256 scaledIn = (balanceIn * remainingOut).ceilDiv(balanceOut);

            uint256 ask = bound(asks[i], 1, balanceIn);
            uint256 expectedNet = Math.min(ask - ask * feeBps / BPS, scaledIn);
            uint256 expectedOut = expectedNet >= scaledIn ? remainingOut : expectedNet * remainingOut / scaledIn;
            uint256 expectedFlat = expectedNet == ask - ask * feeBps / BPS
                ? ask * feeBps / BPS
                : expectedNet * feeBps / (BPS - feeBps);

            // InvalidateTokenOut scales the estimate by this fill's output over the whole order, rounding up
            uint256 share = (estimate * expectedOut).ceilDiv(balanceOut);
            uint256 expectedFee = expectedFlat + (expectedNet > share ? expectedNet - share : 0) * surplusBps / BPS;

            uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
            try swapVM.swap(order, ask, exactInData) returns (uint256 amountIn, uint256 amountOut, bytes32) {
                assertEq(amountIn, expectedNet + expectedFlat);
                assertEq(amountOut, expectedOut);
                assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, expectedFee, "Flat and surplus fees should be counted against the real fill");

                filledOut += expectedOut;
                totalShares += share;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
                assertEq(expectedOut, 0);
            }
        }

        // Estimate shares across all fills never exceed the whole-order estimate beyond ceil slack
        assertLe(totalShares, estimate + asks.length, "Cumulative estimate shares should be pro-rata of the order");
    }

    function testFuzz_SurplusOut_Multifill(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 estimate,
        uint24 feeBps,
        uint24 surplusBps,
        uint256[3] memory asks
    ) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        estimate = bound(estimate, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, 0.5e7));
        surplusBps = uint24(bound(surplusBps, 1, BPS - 1));

        ISwapVM.Order memory order = _flatSurplusOrder(false, balanceIn, balanceOut, feeBps, surplusBps, estimate);
        bytes memory exactOutData = _makeTakerData(order, false);

        uint256 filledIn;
        uint256 totalShares;
        for (uint256 i = 0; i < asks.length; i++) {
            uint256 remainingIn = balanceIn - filledIn;
            if (remainingIn == 0) break;

            // InvalidateTokenIn restores the remaining capacity, rounding the output side down
            uint256 scaledOut = balanceOut * remainingIn / balanceIn;
            if (scaledOut == 0) break; // Tail dust quotes to zero output and cannot be filled

            // Gross output requested with the flat fee on top, capped by the remaining capacity
            uint256 ask = bound(asks[i], 1, balanceOut);
            uint256 expectedGross = Math.min(ask + ask * feeBps / (BPS - feeBps), scaledOut);
            uint256 expectedIn = expectedGross >= scaledOut ? remainingIn : (expectedGross * remainingIn).ceilDiv(scaledOut);
            uint256 expectedOut = expectedGross - expectedGross * feeBps / BPS;

            // InvalidateTokenIn scales the estimate by this fill's input over the whole order, rounding down;
            // the surplus is the estimate share shortfall against the really delivered gross
            uint256 share = estimate * expectedIn / balanceIn;
            uint256 expectedFee = expectedGross * feeBps / BPS + (share > expectedGross ? share - expectedGross : 0) * surplusBps / BPS;

            uint256 recipientBefore = tokenB.balanceOf(feeRecipient);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, ask, exactOutData);

            assertEq(amountIn, expectedIn);
            assertEq(amountOut, expectedOut);
            assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, expectedFee, "Flat and surplus fees should be counted against the real fill");

            filledIn += expectedIn;
            totalShares += share;
        }

        // Estimate shares across all fills never exceed the whole-order estimate
        assertLe(totalShares, estimate, "Cumulative estimate shares should be pro-rata of the order");
    }

    /// @dev Fusion-style Dutch auction: maker sells a fixed 200e18 output (InvalidateTokenOut) with the
    ///   order priced at the auction maximum of 100e18 input, scaled down over time
    ///   (PiecewiseLinearScaleBalanceIn, here frozen at 0.75). The maker estimates receiving the 50e18
    ///   auction minimum, so the premium above it is the surplus: each half fill pays 37.5e18 against
    ///   a 25e18 estimate share -> surplus 12.5e18, fee 1.25e18.
    function test_SurplusIn_PiecewiseLinearAuction_ProRataEstimate() public {
        uint16[] memory durations = new uint16[](1);
        durations[0] = 100;
        uint24[] memory scales = new uint24[](2);
        scales[0] = 12582911; // (scale + 1) / 2^24 = 0.75
        scales[1] = 12582911;

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            InvalidateTokenOut.build(),
            PiecewiseLinearScaleBalanceIn.build(uint40(block.timestamp + 1000), durations, scales),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 50e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _makeTakerData(order, false);

        for (uint256 fill = 0; fill < 2; fill++) {
            uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
            uint256 makerBefore = tokenA.balanceOf(maker);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactOutData);

            assertEq(amountOut, 100e18);
            assertEq(amountIn, 37.5e18, "Auction price: 50e18 max input scaled 0.75x");
            assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1.25e18, "10% of the 12.5e18 surplus over the estimated minimum");
            assertEq(tokenA.balanceOf(maker) - makerBefore, 36.25e18, "Maker receives input minus surplus fee");
        }

        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 200e18);
    }

    /// @dev Without a token invalidator nothing scales the estimate: it applies to each fill in full.
    ///   A fill paying above the whole-order estimate is charged the whole shortfall every time.
    function test_SurplusIn_NoInvalidator_EstimateAppliesInFull() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 40e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _makeTakerData(order, true);

        // Nothing invalidates the order: identical half fills are re-charged against the full estimate
        for (uint256 fill = 0; fill < 2; fill++) {
            uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 50e18, exactInData);

            assertEq(amountIn, 50e18);
            assertEq(amountOut, 100e18);
            // realIn 50e18 vs the full 40e18 estimate -> surplus 10e18, fee 1e18
            assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1e18, "Full estimate applies to every fill");
        }
    }

    /// @dev Without a token invalidator a partial fill below the whole-order estimate pays no surplus fee
    function test_SurplusIn_NoInvalidator_NoSurplusBelowEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 80e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _makeTakerData(order, true);

        uint256 makerBefore = tokenA.balanceOf(maker);
        (uint256 amountIn,,) = swapVM.swap(order, 50e18, exactInData);

        assertEq(amountIn, 50e18);
        assertEq(tokenA.balanceOf(feeRecipient), 0, "realIn 50e18 below the full 80e18 estimate: no surplus");
        assertEq(tokenA.balanceOf(maker) - makerBefore, 50e18, "Maker receives the full input");
    }

    /// @dev Without a token invalidator the token-out estimate also applies in full: the maker pays the
    ///   surplus fee on the whole-order shortfall even for a partial fill. Makers taking surplus-out fees
    ///   are expected to track the order with InvalidateTokenIn (or accept full-amount fills only).
    function test_SurplusOut_NoInvalidator_EstimateAppliesInFull() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeBuilders.protocolSurplusOut(0.1e7, feeRecipient, 240e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _makeTakerData(order, false);

        uint256 makerBefore = tokenB.balanceOf(maker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactOutData);

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18);
        // realOut 100e18 vs the full 240e18 estimate -> surplus 140e18, fee 14e18 paid by the maker
        assertEq(tokenB.balanceOf(feeRecipient), 14e18, "Full estimate applies to the partial fill");
        assertEq(makerBefore - tokenB.balanceOf(maker), 114e18, "Maker pays the output and the surplus fee");
    }

    /// @dev Canonical program: the invalidator tracks the maker's fixed axis and precedes FeeProtocol,
    ///   while the fee/surplus token sits on the opposite (floating) axis
    function _flatSurplusOrder(bool isTokenIn, uint256 balanceIn, uint256 balanceOut, uint24 feeBps, uint24 surplusBps, uint256 estimate) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            isTokenIn ? InvalidateTokenOut.build() : InvalidateTokenIn.build(),
            isTokenIn
                ? FeeBuilders.protocolFlatSurplusIn(feeBps, surplusBps, feeRecipient, uint216(estimate))
                : FeeBuilders.protocolFlatSurplusOut(feeBps, surplusBps, feeRecipient, uint216(estimate)),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
    }

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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
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

/// @notice Unit tests for the decrease-only, maker-favoring surplus estimate scaling
contract FeeMetaScaleSurplusEstimateTest is Test {
    using FeeMetaLib for FeeMeta;

    function scaleExternal(FeeMeta meta, uint256 num, uint256 denom) external pure returns (FeeMeta) {
        return meta.scaleSurplusEstimate(num, denom);
    }

    function test_ScaleSurplusEstimate_RoundsForMaker() public pure {
        // Token-in estimate rounds up: bigger estimate -> smaller surplus charged off the maker's input
        FeeMeta metaIn = FeeMetaLib.encode(true, 3, 123, 100);
        assertEq(metaIn.scaleSurplusEstimate(1, 3).decodeSurplusEstimate(), 34);

        // Token-out estimate rounds down: smaller estimate -> smaller shortfall paid by the maker
        FeeMeta metaOut = FeeMetaLib.encode(false, 3, 123, 100);
        assertEq(metaOut.scaleSurplusEstimate(1, 3).decodeSurplusEstimate(), 33);
    }

    function test_ScaleSurplusEstimate_PreservesMetaFields() public pure {
        FeeMeta meta = FeeMetaLib.encode(true, 7, 456, 1000).scaleSurplusEstimate(1, 4);

        assertEq(meta.decodeSurplusEstimate(), 250);
        assertTrue(meta.decodeIsTokenIn());
        assertEq(meta.decodeCount(), 7);
        assertEq(meta.decodeTotalBps(), 456);
    }

    function test_ScaleSurplusEstimate_FullFillKeepsEstimate() public pure {
        FeeMeta meta = FeeMetaLib.encode(false, 1, 0, 1e18).scaleSurplusEstimate(5e17, 5e17);
        assertEq(meta.decodeSurplusEstimate(), 1e18, "num == denom is a full fill of the remaining order");
    }

    function test_ScaleSurplusEstimate_Revert_ScaleUp() public {
        FeeMeta meta = FeeMetaLib.encode(true, 1, 0, 100);

        vm.expectRevert(FeeMetaLib.FeeMetaSurplusScaleUp.selector);
        this.scaleExternal(meta, 4, 3);
    }
}
