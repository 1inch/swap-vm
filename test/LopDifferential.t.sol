// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LopParityBase } from "./base/LopParityBase.sol";

/// @title  LopDifferential — true differential parity against the real Limit Order Protocol.
/// @notice Each test deploys the actual LimitOrderProtocol contract, builds an economically identical
///         SwapVM program from a shared {OrderSpec}, fills both with a shared {FillSpec}, and asserts
///         the two platforms agree: either both revert, or both succeed with the same
///         (makerAsset out, takerAsset in). This is the on-chain counterpart to the inline-math oracle
///         in LimitOrderParity.t.sol (which is kept as a faster check).
contract LopDifferentialTest is LopParityBase {
    uint256 internal constant MAX_AMOUNT = 1e38; // products stay < uint256 max

    // =============================================================================================
    // Core parity assertion: run the same order+fill on both platforms and compare.
    // =============================================================================================

    function _assertParity(OrderSpec memory spec, FillSpec memory fs) internal returns (FillResult memory lopRes) {
        FillResult memory l = _fillLop(spec, fs);
        FillResult memory v = _fillVm(spec, fs);

        assertEq(v.ok, l.ok, "parity: one platform reverted while the other succeeded");
        if (l.ok) {
            assertEq(v.makerAssetOut, l.makerAssetOut, "parity: makerAsset out (LOP makingAmount vs VM amountOut)");
            assertEq(v.takerAssetIn, l.takerAssetIn, "parity: takerAsset in (LOP takingAmount vs VM amountIn)");
        }
        return l;
    }

    // =============================================================================================
    // 1. Partial-fill parity (single fill, fully random direction & amount within the order).
    // =============================================================================================

    function testFuzz_PartialFill_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 rawAmount,
        bool byMakingAmount,
        bool allowMultipleFills
    ) public {
        makingAmount = bound(makingAmount, 1, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 1, MAX_AMOUNT);

        OrderSpec memory spec = _baseSpec(makingAmount, takingAmount, true, allowMultipleFills, 0);

        // Keep the request within the order's size (over-request is a known LOP-clamps/VM-reverts gap).
        uint256 amount = byMakingAmount ? bound(rawAmount, 1, makingAmount) : bound(rawAmount, 1, takingAmount);
        FillSpec memory fs = FillSpec({ byMakingAmount: byMakingAmount, amount: amount, hasThreshold: false, threshold: 0 });

        FillResult memory l = _assertParity(spec, fs);

        // Cross-check the agreed amounts against LOP's linear formula (maker-favouring rounding).
        if (l.ok) {
            if (byMakingAmount) {
                assertEq(l.makerAssetOut, amount, "exactOut: makerAsset out == requested");
                assertEq(l.takerAssetIn, Math.mulDiv(amount, takingAmount, makingAmount, Math.Rounding.Ceil), "exactOut: ceil");
            } else {
                assertEq(l.takerAssetIn, amount, "exactIn: takerAsset in == requested");
                assertEq(l.makerAssetOut, Math.mulDiv(amount, makingAmount, takingAmount), "exactIn: floor");
            }
        }
    }

    // =============================================================================================
    // 2. Full-fill-only parity (LOP NO_PARTIAL_FILLS  <=>  VM _limitSwapOnlyFull1D).
    // =============================================================================================

    function testFuzz_FullFillOnly_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        bool byMakingAmount
    ) public {
        makingAmount = bound(makingAmount, 1, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 1, MAX_AMOUNT);

        OrderSpec memory spec = _baseSpec(makingAmount, takingAmount, false, false, 0);

        // Full fill: request the whole side. Both platforms must succeed with the full amounts.
        uint256 full = byMakingAmount ? makingAmount : takingAmount;
        FillResult memory l = _assertParity(spec, FillSpec({ byMakingAmount: byMakingAmount, amount: full, hasThreshold: false, threshold: 0 }));
        if (l.ok) {
            assertEq(l.makerAssetOut, makingAmount, "full fill: makerAsset out == makingAmount");
            assertEq(l.takerAssetIn, takingAmount, "full fill: takerAsset in == takingAmount");
        }

        // A strictly-partial request must be rejected by BOTH platforms.
        if (makingAmount > 1 && takingAmount > 1) {
            uint256 partialAmount = byMakingAmount ? makingAmount / 2 : takingAmount / 2;
            if (partialAmount > 0) {
                FillResult memory lp = _fillLop(spec, FillSpec({ byMakingAmount: byMakingAmount, amount: partialAmount, hasThreshold: false, threshold: 0 }));
                FillResult memory vp = _fillVm(spec, FillSpec({ byMakingAmount: byMakingAmount, amount: partialAmount, hasThreshold: false, threshold: 0 }));
                assertFalse(lp.ok, "full-fill-only: LOP must reject partial");
                assertFalse(vp.ok, "full-fill-only: VM must reject partial");
            }
        }
    }

    // =============================================================================================
    // 3. Threshold parity (LOP MakingAmountTooLow / TakingAmountTooHigh).
    // =============================================================================================

    function testFuzz_Threshold_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 rawAmount,
        uint256 rawThreshold,
        bool byMakingAmount
    ) public {
        makingAmount = bound(makingAmount, 1, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 1, MAX_AMOUNT);

        OrderSpec memory spec = _baseSpec(makingAmount, takingAmount, true, true, 0);

        uint256 amount = byMakingAmount ? bound(rawAmount, 1, makingAmount) : bound(rawAmount, 1, takingAmount);

        // The true achievable counter-amount, then a threshold straddling it by +/- a small window
        // so the fuzzer exercises both the passing and the reverting side.
        uint256 trueCounter = byMakingAmount
            ? Math.mulDiv(amount, takingAmount, makingAmount, Math.Rounding.Ceil) // takerAsset in (max-in threshold)
            : Math.mulDiv(amount, makingAmount, takingAmount);                    // makerAsset out (min-out threshold)
        uint256 window = trueCounter / 4 + 2;
        uint256 threshold = bound(rawThreshold, trueCounter > window ? trueCounter - window : 0, trueCounter + window);

        FillSpec memory fs = FillSpec({ byMakingAmount: byMakingAmount, amount: amount, hasThreshold: true, threshold: threshold });
        _assertParity(spec, fs);
    }

    // =============================================================================================
    // 4. Expiry parity (LOP isExpired  <=>  VM Controls._deadline).
    // =============================================================================================

    function testFuzz_Expiry_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        uint40 expiry,
        uint256 warpTo
    ) public {
        makingAmount = bound(makingAmount, 1, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 1, MAX_AMOUNT);
        expiry = uint40(bound(expiry, 1, type(uint40).max - 1)); // non-zero so the order has an expiry
        warpTo = bound(warpTo, BASE_TS, type(uint40).max);
        vm.warp(warpTo);

        OrderSpec memory spec = _baseSpec(makingAmount, takingAmount, true, true, expiry);

        // exactIn fill of the whole takerAsset side (always produces non-zero output here).
        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: takingAmount, hasThreshold: false, threshold: 0 });
        FillResult memory l = _assertParity(spec, fs);

        // Both must agree with the expiry rule: valid iff block.timestamp <= expiry.
        assertEq(l.ok, warpTo <= expiry, "expiry: success must track block.timestamp <= expiry");
    }

    // =============================================================================================
    // 5. Multiple partial fills parity (LOP RemainingInvalidator <=> VM _invalidateTokenOut1D).
    // =============================================================================================

    function testFuzz_MultipleFills_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 seed
    ) public {
        makingAmount = bound(makingAmount, 1e6, MAX_AMOUNT); // room for several partial fills
        takingAmount = bound(takingAmount, 1e6, MAX_AMOUNT);

        OrderSpec memory spec = _baseSpec(makingAmount, takingAmount, true, true, 0);

        // Fill by makerAsset (exactOut) so "remaining" is measured directly in makerAsset units.
        uint256 remaining = makingAmount; // remaining makerAsset
        for (uint256 i = 0; i < 4 && remaining > 1; ++i) {
            // A random slice of the remaining makerAsset, always within the cap.
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 slice = bound(seed % remaining + 1, 1, remaining);
            // Skip slices that would round the required input to 0-output territory is impossible here
            // (exactOut output == slice >= 1), so just fill.
            FillSpec memory fs = FillSpec({ byMakingAmount: true, amount: slice, hasThreshold: false, threshold: 0 });
            FillResult memory l = _assertParity(spec, fs);
            assertTrue(l.ok, "partial fill within remaining must succeed on both");
            assertEq(l.makerAssetOut, slice, "partial fill: makerAsset out == requested slice");
            remaining -= slice;
        }

        // Exhaust whatever remains, then a further fill must revert on BOTH platforms.
        if (remaining > 0) {
            _assertParity(spec, FillSpec({ byMakingAmount: true, amount: remaining, hasThreshold: false, threshold: 0 }));
        }
        FillResult memory lo = _fillLop(spec, FillSpec({ byMakingAmount: true, amount: 1, hasThreshold: false, threshold: 0 }));
        FillResult memory vo = _fillVm(spec, FillSpec({ byMakingAmount: true, amount: 1, hasThreshold: false, threshold: 0 }));
        assertFalse(lo.ok, "exhausted order: LOP must reject further fills");
        assertFalse(vo.ok, "exhausted order: VM must reject further fills");
    }

    // =============================================================================================
    // 6. Fully-random combined parity — the headline test.
    //    Fuzzes the ENTIRE MakerTraits surface plus the fill. Specs SwapVM cannot replicate
    //    (private orders, epoch/series, extension, permit2, weth-unwrap, interactions) are skipped
    //    per spec — the LOP builder still encodes them, there is just nothing to compare against.
    // =============================================================================================

    function testFuzz_Combined_Parity(
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 rawAmount,
        uint256 rawThreshold,
        uint40 expiry,
        uint256 warpDelta,
        uint40 nonceOrEpoch,
        uint16 flags
    ) public {
        makingAmount = bound(makingAmount, 1, MAX_AMOUNT);
        takingAmount = bound(takingAmount, 1, MAX_AMOUNT);

        bool byMakingAmount = (flags & 0x0001) != 0;
        bool hasThreshold = (flags & 0x0008) != 0;
        bool hasExpiry = (flags & 0x0010) != 0;

        OrderSpec memory spec;
        spec.makingAmount = makingAmount;
        spec.takingAmount = takingAmount;
        spec.allowPartialFills = (flags & 0x0002) != 0;
        spec.allowMultipleFills = (flags & 0x0004) != 0;
        // Bound to uint32 so the epoch opcode value (uint32) matches LOP's nonceOrEpoch exactly when
        // the epoch manager is engaged; for bit-invalidator orders the index value is parity-neutral.
        spec.nonceOrEpoch = uint40(uint32(nonceOrEpoch));
        // The advanced (non-replicable) MakerTraits are fuzzed behind a single gate so the builder is
        // exercised across the whole surface while keeping ~half the runs replicable (which then assert
        // parity); gated runs are skipped below. Without the gate, replicable specs would be ~1% of runs.
        if ((flags & 0x0020) != 0) {
            spec.allowedSender = (flags & 0x0040) != 0 ? address(0xBEEF) : address(0);
            spec.needCheckEpoch = (flags & 0x0080) != 0;
            spec.usePermit2 = (flags & 0x0100) != 0;
            spec.unwrapWeth = (flags & 0x0200) != 0;
            // Maker interactions ARE replicable (hooks) — when set without a non-replicable trait the
            // run still asserts parity, with the recorder hook firing on both platforms.
            spec.preInteraction = (flags & 0x0400) != 0;
            spec.postInteraction = (flags & 0x0800) != 0;
        }

        // Random expiry + time travel: drives both the "valid" and "expired" branches.
        if (hasExpiry) {
            spec.expiry = uint40(bound(expiry, BASE_TS, type(uint40).max));
            vm.warp(BASE_TS + bound(warpDelta, 0, uint256(type(uint40).max) - BASE_TS));
        }

        // Skip specs with no SwapVM equivalent (the builder encoded them; there is nothing to compare).
        if (!_swapVmReplicable(spec)) return;

        // Amount within the order side. For full-fill-only orders a partial request would revert on
        // both (consistent), but to keep the success branch reachable we request the full side there.
        uint256 maxSide = byMakingAmount ? makingAmount : takingAmount;
        uint256 amount = spec.allowPartialFills ? bound(rawAmount, 1, maxSide) : maxSide;

        uint256 threshold = 0;
        if (hasThreshold) {
            uint256 trueCounter = byMakingAmount
                ? Math.mulDiv(amount, takingAmount, makingAmount, Math.Rounding.Ceil)
                : Math.mulDiv(amount, makingAmount, takingAmount);
            uint256 window = trueCounter / 4 + 2;
            threshold = bound(rawThreshold, trueCounter > window ? trueCounter - window : 0, trueCounter + window);
        }

        FillSpec memory fs = FillSpec({
            byMakingAmount: byMakingAmount,
            amount: amount,
            hasThreshold: hasThreshold,
            threshold: threshold
        });

        // The whole point: whatever the random replicable combination, both platforms must agree.
        _assertParity(spec, fs);
    }

    // =============================================================================================
    // 8. Private orders — LOP allowedSender <=> SwapVM Whitelist._whitelistSingleTaker.
    //    An order restricted to the filling taker succeeds on both platforms; one restricted to a
    //    different address reverts on both. (LOP matches the low 80 bits of allowedSender, SwapVM the
    //    full address — identical outcomes for the distinct addresses used here.)
    // =============================================================================================

    function test_PrivateOrder_EnforcedOnBothPlatforms() public {
        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 500e18, hasThreshold: false, threshold: 0 });

        // Allowed == the taker (this contract): both platforms fill, amounts match.
        OrderSpec memory allowed = _baseSpec(1000e18, 2000e18, true, true, 0);
        allowed.allowedSender = taker;
        assertTrue(_swapVmReplicable(allowed), "private order is replicable");
        FillResult memory l = _fillLop(allowed, fs);
        FillResult memory v = _fillVm(allowed, fs);
        assertTrue(l.ok, "LOP: allowed taker fills");
        assertTrue(v.ok, "VM: allowed taker fills");
        assertEq(v.makerAssetOut, l.makerAssetOut, "private(allowed): makerAsset out parity");
        assertEq(v.takerAssetIn, l.takerAssetIn, "private(allowed): takerAsset in parity");

        // Restricted to someone else: the filler is `taker`, so both platforms reject.
        OrderSpec memory denied = _baseSpec(1000e18, 2000e18, true, true, 0);
        denied.allowedSender = makeAddr("someoneElse");
        assertFalse(_fillLop(denied, fs).ok, "LOP rejects non-whitelisted taker");
        assertFalse(_fillVm(denied, fs).ok, "VM rejects non-whitelisted taker");
    }

    // =============================================================================================
    // 8b. Epoch management — LOP needCheckEpochManager(series, epoch) <=>
    //     SwapVM SeriesEpochManager._validateSeriesEpochXD. An order pinned to (series, epoch) is valid
    //     on both platforms only while the maker's epoch for that series matches; advancing the epoch
    //     on both invalidates lower-epoch orders. (LOP requires partial+multiple here — it forbids
    //     combining the epoch manager with the bit invalidator.)
    // =============================================================================================

    function test_EpochManagement_ParityAcrossAdvance() public {
        uint40 series = 7;
        uint40 pinnedEpoch = 3;
        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 100e18, hasThreshold: false, threshold: 0 });

        OrderSpec memory spec = _baseSpec(1000e18, 2000e18, true, true, 0);
        spec.needCheckEpoch = true;
        spec.series = series;
        spec.nonceOrEpoch = pinnedEpoch;
        assertTrue(_swapVmReplicable(spec), "epoch order (partial+multiple) is replicable");

        // Maker epoch starts at 0 on both => order pinned to epoch 3 is invalid on both.
        assertFalse(_fillLop(spec, fs).ok, "LOP: epoch mismatch before advance");
        assertFalse(_fillVm(spec, fs).ok, "VM: epoch mismatch before advance");

        // Maker advances the series epoch to 3 on BOTH platforms.
        vm.startPrank(maker);
        lop.advanceEpoch(uint96(series), 3);
        swapVM.seriesEpochAdvance(series, 3);
        vm.stopPrank();

        // Now the pinned-epoch order is valid on both, with matching amounts.
        FillResult memory l = _fillLop(spec, fs);
        FillResult memory v = _fillVm(spec, fs);
        assertTrue(l.ok, "LOP fills at matching epoch");
        assertTrue(v.ok, "VM fills at matching epoch");
        assertEq(v.makerAssetOut, l.makerAssetOut, "epoch: makerAsset out parity");
        assertEq(v.takerAssetIn, l.takerAssetIn, "epoch: takerAsset in parity");

        // An order pinned to the now-stale epoch 0 is invalid on both.
        OrderSpec memory stale = spec;
        stale.nonceOrEpoch = 0;
        assertFalse(_fillLop(stale, fs).ok, "LOP: stale epoch rejected");
        assertFalse(_fillVm(stale, fs).ok, "VM: stale epoch rejected");
    }

    // =============================================================================================
    // 7. Concrete balance-delta check — proves the compared return values reflect real transfers.
    // =============================================================================================

    function test_BalanceDeltas_MatchReturns() public {
        OrderSpec memory spec = _baseSpec(1000e18, 2000e18, true, true, 0); // rate: 1 makerAsset per 2 takerAsset
        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 500e18, hasThreshold: false, threshold: 0 });

        // ---- LOP ----
        uint256 aBefore = tokenA.balanceOf(taker);
        uint256 bBefore = tokenB.balanceOf(taker);
        FillResult memory l = _fillLop(spec, fs);
        assertTrue(l.ok);
        assertEq(aBefore - tokenA.balanceOf(taker), l.takerAssetIn, "LOP: tokenA out == takingAmount");
        assertEq(tokenB.balanceOf(taker) - bBefore, l.makerAssetOut, "LOP: tokenB in == makingAmount");

        // ---- SwapVM ----
        aBefore = tokenA.balanceOf(taker);
        bBefore = tokenB.balanceOf(taker);
        FillResult memory v = _fillVm(spec, fs);
        assertTrue(v.ok);
        assertEq(aBefore - tokenA.balanceOf(taker), v.takerAssetIn, "VM: tokenA out == amountIn");
        assertEq(tokenB.balanceOf(taker) - bBefore, v.makerAssetOut, "VM: tokenB in == amountOut");

        // ---- parity ----
        assertEq(v.takerAssetIn, l.takerAssetIn, "takerAsset in parity");
        assertEq(v.makerAssetOut, l.makerAssetOut, "makerAsset out parity");
        assertEq(l.takerAssetIn, 500e18);
        assertEq(l.makerAssetOut, 250e18);
    }

    // =============================================================================================
    // 9. Maker interactions — LOP pre/post-interaction <=> SwapVM maker hooks.
    //    The shared recorder mock is the interaction target on both platforms; after each fill we
    //    assert exactly one new record carrying the maker payload appeared.
    // =============================================================================================

    /// @notice Concrete check: an order with both interactions records the right payloads on each
    ///         platform (LOP pre/postInteraction; SwapVM preTransferOut/postTransferIn hooks), and the
    ///         amounts still match — interactions don't change the economics.
    function test_Interactions_RecordedOnBothPlatforms() public {
        bytes memory preData = abi.encode("PRE", uint256(0xC0FFEE));
        bytes memory postData = abi.encode("POST", uint256(0xBADB0B));

        OrderSpec memory spec = _baseSpec(1000e18, 2000e18, true, true, 0);
        spec.preInteraction = true;
        spec.postInteraction = true;
        spec.preInteractionData = preData;
        spec.postInteractionData = postData;

        assertTrue(_swapVmReplicable(spec), "maker interactions must be SwapVM-replicable");

        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 500e18, hasThreshold: false, threshold: 0 });

        // ---- LOP: fillOrderArgs runs preInteraction (before) then postInteraction (after) ----
        uint256 lPre = recorder.recordsLength(recorder.PRE_INTERACTION());
        uint256 lPost = recorder.recordsLength(recorder.POST_INTERACTION());
        FillResult memory l = _fillLop(spec, fs);
        assertTrue(l.ok, "LOP fill with interactions must succeed");
        assertEq(recorder.recordsLength(recorder.PRE_INTERACTION()), lPre + 1, "LOP: one new pre record");
        assertEq(recorder.recordsLength(recorder.POST_INTERACTION()), lPost + 1, "LOP: one new post record");
        assertEq(recorder.lastRecord(recorder.PRE_INTERACTION()), preData, "LOP: pre payload");
        assertEq(recorder.lastRecord(recorder.POST_INTERACTION()), postData, "LOP: post payload");

        // ---- SwapVM: preTransferOut hook (before) and postTransferIn hook (after) ----
        uint256 vPre = recorder.recordsLength(recorder.PRE_TRANSFER_OUT());
        uint256 vPost = recorder.recordsLength(recorder.POST_TRANSFER_IN());
        FillResult memory v = _fillVm(spec, fs);
        assertTrue(v.ok, "VM fill with hooks must succeed");
        assertEq(recorder.recordsLength(recorder.PRE_TRANSFER_OUT()), vPre + 1, "VM: one new pre-hook record");
        assertEq(recorder.recordsLength(recorder.POST_TRANSFER_IN()), vPost + 1, "VM: one new post-hook record");
        assertEq(recorder.lastRecord(recorder.PRE_TRANSFER_OUT()), preData, "VM: pre payload");
        assertEq(recorder.lastRecord(recorder.POST_TRANSFER_IN()), postData, "VM: post payload");

        assertEq(v.makerAssetOut, l.makerAssetOut, "interactions: makerAsset out parity");
        assertEq(v.takerAssetIn, l.takerAssetIn, "interactions: takerAsset in parity");
    }

    /// @notice Fuzzed payloads and any pre/post combination: each enabled interaction records exactly
    ///         its bytes on both platforms; disabled ones record nothing.
    function testFuzz_Interactions_RecordPayloads(bytes calldata preData, bytes calldata postData, uint8 mode) public {
        bool pre = (mode & 0x01) != 0;
        bool post = (mode & 0x02) != 0;
        if (!pre && !post) return; // nothing to assert
        vm.assume(preData.length <= 512 && postData.length <= 512);

        OrderSpec memory spec = _baseSpec(1000e18, 2000e18, true, true, 0);
        spec.preInteraction = pre;
        spec.postInteraction = post;
        spec.preInteractionData = preData;
        spec.postInteractionData = postData;

        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 100e18, hasThreshold: false, threshold: 0 });

        // ---- LOP ----
        uint256 lPre = recorder.recordsLength(recorder.PRE_INTERACTION());
        uint256 lPost = recorder.recordsLength(recorder.POST_INTERACTION());
        FillResult memory l = _fillLop(spec, fs);
        assertTrue(l.ok, "LOP fill must succeed");
        assertEq(recorder.recordsLength(recorder.PRE_INTERACTION()), pre ? lPre + 1 : lPre, "LOP pre count");
        assertEq(recorder.recordsLength(recorder.POST_INTERACTION()), post ? lPost + 1 : lPost, "LOP post count");
        if (pre) assertEq(recorder.lastRecord(recorder.PRE_INTERACTION()), preData, "LOP pre payload");
        if (post) assertEq(recorder.lastRecord(recorder.POST_INTERACTION()), postData, "LOP post payload");

        // ---- SwapVM ----
        uint256 vPre = recorder.recordsLength(recorder.PRE_TRANSFER_OUT());
        uint256 vPost = recorder.recordsLength(recorder.POST_TRANSFER_IN());
        FillResult memory v = _fillVm(spec, fs);
        assertTrue(v.ok, "VM fill must succeed");
        assertEq(recorder.recordsLength(recorder.PRE_TRANSFER_OUT()), pre ? vPre + 1 : vPre, "VM pre count");
        assertEq(recorder.recordsLength(recorder.POST_TRANSFER_IN()), post ? vPost + 1 : vPost, "VM post count");
        if (pre) assertEq(recorder.lastRecord(recorder.PRE_TRANSFER_OUT()), preData, "VM pre payload");
        if (post) assertEq(recorder.lastRecord(recorder.POST_TRANSFER_IN()), postData, "VM post payload");

        assertEq(v.makerAssetOut, l.makerAssetOut, "interactions: makerAsset out parity");
        assertEq(v.takerAssetIn, l.takerAssetIn, "interactions: takerAsset in parity");
    }

    // =============================================================================================
    // 10. Maker UNWRAP_WETH — takerAsset is WETH and the maker receives ETH.
    //     LOP makerTraits.unwrapWeth() == SwapVM shouldUnwrapWeth (signature path / _transferFrom).
    //     The taker pays WETH (transferFrom) on both — the path both platforms share. (LOP also allows
    //     the taker to pay *native ETH* via msg.value, which SwapVM has no equivalent for since swap()
    //     is not payable; that path is intentionally out of scope.) This lives in its own test because
    //     the generic fuzz's takerAsset is a plain ERC20, where unwrapWeth is a meaningless no-op flag.
    // =============================================================================================

    function test_UnwrapWeth_MakerReceivesEth_OnBothPlatforms() public {
        // Repoint the takerAsset (tokenIn) at WETH; the maker will get the incoming WETH as ETH.
        takerAssetToken = address(weth);

        OrderSpec memory spec = _baseSpec(1000e18, 2000e18, true, true, 0);
        spec.unwrapWeth = true;

        // exactIn: taker pays 500 WETH, maker gives floor(500*1000/2000) = 250 tokenB.
        FillSpec memory fs = FillSpec({ byMakingAmount: false, amount: 500e18, hasThreshold: false, threshold: 0 });

        // Fund the taker (this contract) with WETH for both fills and approve both venues.
        vm.deal(address(this), 1000e18);
        weth.deposit{ value: 1000e18 }();
        IERC20(address(weth)).approve(address(lop), type(uint256).max);
        IERC20(address(weth)).approve(address(swapVM), type(uint256).max);

        // ---- LOP: maker receives ETH, not WETH ----
        uint256 makerEthBefore = maker.balance;
        uint256 makerWethBefore = IERC20(address(weth)).balanceOf(maker);
        FillResult memory l = _fillLop(spec, fs);
        assertTrue(l.ok, "LOP unwrap fill must succeed");
        assertEq(maker.balance - makerEthBefore, l.takerAssetIn, "LOP: maker ETH += takingAmount");
        assertEq(IERC20(address(weth)).balanceOf(maker), makerWethBefore, "LOP: maker WETH unchanged");

        // ---- SwapVM: same outcome via shouldUnwrapWeth ----
        makerEthBefore = maker.balance;
        makerWethBefore = IERC20(address(weth)).balanceOf(maker);
        FillResult memory v = _fillVm(spec, fs);
        assertTrue(v.ok, "VM unwrap fill must succeed");
        assertEq(maker.balance - makerEthBefore, v.takerAssetIn, "VM: maker ETH += amountIn");
        assertEq(IERC20(address(weth)).balanceOf(maker), makerWethBefore, "VM: maker WETH unchanged");

        // ---- parity ----
        assertEq(v.takerAssetIn, l.takerAssetIn, "unwrap: takerAsset in parity");
        assertEq(v.makerAssetOut, l.makerAssetOut, "unwrap: makerAsset out parity");
        assertEq(l.takerAssetIn, 500e18);
        assertEq(l.makerAssetOut, 250e18);
    }

}
