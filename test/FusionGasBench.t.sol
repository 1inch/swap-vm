// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { FusionParityBase } from "./base/FusionParityBase.sol";

/// @title  FusionGasBench — SwapVM vs 1inch Fusion, basic Dutch-auction order (NO gas bump).
/// @notice Extends the LOP benchmark to Fusion (see {LopGasBench}): builds the SAME economic order — a
///         single-segment Dutch auction — on real Fusion and on its SwapVM replica, then on each platform
///         and across the auction it:
///           - VALUE: asserts both fills succeed and deliver the full makingAmount, and reports the exact
///             SwapVM-vs-Fusion difference in taker-asset paid in (the maths differ; no estimated bound).
///           - GAS: meters the fill call on each platform (drift-free, in a fresh frame) and reports avg /
///             worst gas and the SwapVM-vs-Fusion divergence. Execution gas only (calldata excluded), same
///             caveat as LopGasBench.
///
///         Run:  forge test --match-contract FusionGasBench -vv
contract FusionGasBench is FusionParityBase {
    uint256 internal constant SAMPLES = 16;

    // Auction geometry shared by every sample. Single linear segment, no gas bump.
    uint32 internal constant AUCTION_START = uint32(BASE_TS);
    uint24 internal constant AUCTION_DURATION = 1800; // 30 min, fits one uint16 SwapVM scale segment
    uint24 internal constant INITIAL_RATE_BUMP = 1_000_000; // 10% in Fusion's 1e7 base

    // ---- inputs -------------------------------------------------------------------------------------

    /// @dev Deterministic input #i (scripts have no RNG): amounts in [1e12, 1e30).
    function _sample(uint256 i) internal pure returns (uint256 makingAmount, uint256 takingAmount) {
        uint256 span = 1e30 - 1e12;
        makingAmount = 1e12 + (uint256(keccak256(abi.encode("fusion.making", i))) % span);
        takingAmount = 1e12 + (uint256(keccak256(abi.encode("fusion.taking", i))) % span);
    }

    function _spec(uint256 makingAmount, uint256 takingAmount, bool allowPartialFills, bool allowMultipleFills) internal pure returns (OrderSpec memory) {
        return _baseSpec(makingAmount, takingAmount, AUCTION_START, AUCTION_DURATION, INITIAL_RATE_BUMP, allowPartialFills, allowMultipleFills);
    }

    /// @dev Full exact-out buy: the taker buys the entire makingAmount; the priced side is takingAmount.
    function _fullBuy(uint256 makingAmount) internal pure returns (FillSpec memory) {
        return FillSpec({ byMakingAmount: true, amount: makingAmount, hasThreshold: false, threshold: 0 });
    }

    /// @dev Auction phases sampled as fractions of the duration in bps, plus just-before / just-after.
    function _phaseTimestamps() internal pure returns (uint256[] memory ts) {
        ts = new uint256[](7);
        ts[0] = AUCTION_START - 1;                                              // before: full initial bump
        ts[1] = AUCTION_START;                                                  // start
        ts[2] = AUCTION_START + (uint256(AUCTION_DURATION) * 2500) / 10000;
        ts[3] = AUCTION_START + (uint256(AUCTION_DURATION) * 5000) / 10000;
        ts[4] = AUCTION_START + (uint256(AUCTION_DURATION) * 7500) / 10000;
        ts[5] = AUCTION_START + AUCTION_DURATION;                               // finish: base price
        ts[6] = AUCTION_START + AUCTION_DURATION + 1;                           // after: base price
    }

    // ---- value parity -------------------------------------------------------------------------------

    /// @notice Across the whole auction both fills succeed and deliver the full makingAmount; report the
    ///         exact taker-asset difference between SwapVM and Fusion (no estimated tolerance).
    function test_FusionDutchAuction_ValueParity() public {
        uint256[] memory phases = _phaseTimestamps();
        uint256 worstAbs;
        uint256 worstRelPpb; // parts per billion

        for (uint256 i = 0; i < SAMPLES; ++i) {
            (uint256 makingAmount, uint256 takingAmount) = _sample(i);
            OrderSpec memory spec = _spec(makingAmount, takingAmount, true, true);
            FillSpec memory fill = _fullBuy(makingAmount);

            for (uint256 j = 0; j < phases.length; ++j) {
                vm.warp(phases[j]);

                uint256 snap = vm.snapshotState();
                FillResult memory fusion = _fillFusion(spec, fill);
                vm.revertToState(snap);

                snap = vm.snapshotState();
                FillResult memory swapVm = _fillVm(spec, fill);
                vm.revertToState(snap);

                assertTrue(fusion.ok, "fusion fill must succeed");
                assertTrue(swapVm.ok, "swapVM fill must succeed");
                assertEq(fusion.makerAssetOut, makingAmount, "fusion: full making bought");
                assertEq(swapVm.makerAssetOut, makingAmount, "swapVM: full making bought");

                uint256 f = fusion.takerAssetIn;
                uint256 v = swapVm.takerAssetIn;
                uint256 diff = f > v ? f - v : v - f;
                if (diff > worstAbs) worstAbs = diff;
                uint256 relPpb = f == 0 ? 0 : (diff * 1e9) / f;
                if (relPpb > worstRelPpb) worstRelPpb = relPpb;
            }
        }

        emit log("");
        emit log("==== Fusion vs SwapVM Dutch-auction value parity (full exact-out buy) ====");
        emit log(string.concat("  worst |taking| divergence: ", vm.toString(worstAbs), " wei"));
        emit log(string.concat("  worst relative divergence: ", vm.toString(worstRelPpb), " ppb"));
    }

    // ---- gas benchmark ------------------------------------------------------------------------------

    /// @notice Meter the full fill on each platform across the auction; report gas + divergence.
    function test_GasBench_FusionDutchAuction() public {
        _warmSharedPaths();

        uint256[] memory phases = _phaseTimestamps();
        int256[] memory swapVmGas = new int256[](SAMPLES * phases.length);
        int256[] memory fusionGas = new int256[](SAMPLES * phases.length);
        uint256 n;

        for (uint256 i = 0; i < SAMPLES; ++i) {
            (uint256 makingAmount, uint256 takingAmount) = _sample(i);
            // allowPartialFills MUST be true for exact-in: Fusion's NO_PARTIAL order rejects an exact-in fill
            // because the auction's ceil-taking / floor-making rounding makes getMaking(taking) land one wei
            // short of full. With partials allowed, SwapVM exact-in still fully fills and Fusion fills ~full.
            OrderSpec memory spec = _spec(makingAmount, takingAmount, true, false);

            for (uint256 j = 0; j < phases.length; ++j) {
                vm.warp(phases[j]);
                // Same configuration (exact-in full fill), different per-platform amount: each side's own
                // taker-asset input that fully buys makingAmount at this auction phase.
                FillSpec memory vmFill = FillSpec({ byMakingAmount: false, amount: _vmCurrentBalanceIn(spec), hasThreshold: false, threshold: 0 });
                FillSpec memory fusionFill = FillSpec({ byMakingAmount: false, amount: _fusionCurrentTakingIn(spec), hasThreshold: false, threshold: 0 });
                swapVmGas[n] = int256(_vmFillGas(spec, vmFill));
                fusionGas[n] = int256(_fusionFillGas(spec, fusionFill));
                ++n;
            }
        }

        _report("fusion dutch auction (no gas bump): full fill, SwapVM vs Fusion", swapVmGas, fusionGas);
    }

    // ---- metering -----------------------------------------------------------------------------------

    /// @dev Metered in storage isolation (snapshot/revert) AND a fresh external frame (meter*Fill) so the
    ///      measurement doesn't drift with loop memory. Reverts if the fill fails.
    function _vmFillGas(OrderSpec memory spec, FillSpec memory fill) internal returns (uint256 gasUsed) {
        uint256 snap = vm.snapshotState();
        gasUsed = this.meterVmFill(spec, fill);
        vm.revertToState(snap);
    }

    function _fusionFillGas(OrderSpec memory spec, FillSpec memory fill) internal returns (uint256 gasUsed) {
        uint256 snap = vm.snapshotState();
        gasUsed = this.meterFusionFill(spec, fill);
        vm.revertToState(snap);
    }

    /// @dev Warm shared infrastructure ONCE (SwapVM router, LOP, settlement, tokens, maker, signature
    ///      recovery, balance slots) so the metered loop is uniformly hot. NOT reverted: warmth must persist
    ///      beneath each metered fill's snapshot/revert. Uses a distinct-amount order, so its orderHash-keyed
    ///      invalidator slot differs from every metered sample's (which therefore stay cold like a first fill).
    function _warmSharedPaths() internal {
        vm.warp(AUCTION_START + AUCTION_DURATION / 2);
        OrderSpec memory warm = _spec(7e18, 13e18, true, true);
        FillSpec memory fill = _fullBuy(7e18);
        _fillVm(warm, fill);
        _fillFusion(warm, fill);
    }

    // ---- reporting (mirrors LopGasBench) ------------------------------------------------------------

    function _report(string memory label, int256[] memory swapVmGas, int256[] memory fusionGas) internal {
        int256 n = int256(swapVmGas.length);
        int256 sumVm;
        int256 worstVm;
        int256 sumFusion;
        int256 worstFusion;
        int256 sumDivGas;
        int256 worstDivGas;
        int256 sumDivPct; // basis points
        int256 worstDivPct;

        for (uint256 i = 0; i < swapVmGas.length; ++i) {
            int256 v = swapVmGas[i];
            int256 l = fusionGas[i];
            sumVm += v;
            sumFusion += l;
            if (i == 0 || v > worstVm) worstVm = v;
            if (i == 0 || l > worstFusion) worstFusion = l;

            int256 divGas = v - l;
            int256 divPct = l != 0 ? (divGas * 10_000) / l : int256(0);
            sumDivGas += divGas;
            sumDivPct += divPct;
            if (i == 0 || divGas > worstDivGas) worstDivGas = divGas;
            if (i == 0 || divPct > worstDivPct) worstDivPct = divPct;
        }

        emit log("");
        emit log(string.concat("==== ", label, "  (", vm.toString(uint256(n)), " samples) ===="));
        emit log(string.concat("  SwapVM gas   avg ", vm.toString(sumVm / n), "   worst ", vm.toString(worstVm)));
        emit log(string.concat("  Fusion gas   avg ", vm.toString(sumFusion / n), "   worst ", vm.toString(worstFusion)));
        emit log(string.concat("  divergence   avg ", vm.toString(sumDivGas / n), " gas / ", _pct(sumDivPct / n)));
        emit log(string.concat("  divergence worst ", vm.toString(worstDivGas), " gas / ", _pct(worstDivPct)));
    }

    function _pct(int256 bps) private pure returns (string memory) {
        bool negative = bps < 0;
        uint256 abs = uint256(negative ? -bps : bps);
        string memory body = string.concat(vm.toString(abs / 100), ".", _twoDigits(abs % 100), "%");
        return negative ? string.concat("-", body) : string.concat("+", body);
    }

    function _twoDigits(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}
