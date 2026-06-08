// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { LopParityBase } from "./base/LopParityBase.sol";

/// @title  LopGasBench — per-feature gas benchmark, SwapVM vs LOP.
/// @notice Gas isn't attributable to a feature from a single order, so each feature's cost is isolated
///         by DIFFERENCING two orders that are identical except for the feature:
///
///             featureGas = gas(order WITH feature) - gas(order WITHOUT feature)
///
///         measured independently on each platform. One test == one feature. It runs the same array of
///         deterministic inputs, collects the per-input cost on each platform, and logs:
///           - SwapVM / LOP feature gas: average and worst, and
///           - divergence (SwapVM - LOP): average and worst, in gas and percent.
///
///         The Baseline test is the exception: it has no "without", so it reports the ABSOLUTE gas of
///         the simplest fillable order (the floor) instead of a delta.
///
///         INTERPRETING THE NUMBERS — this is the *marginal* cost of enabling a flag, which is NOT the
///         same as the cost of the feature's validation code:
///           - On SwapVM every feature is an extra instruction, so it always pays a full runLoop
///             dispatch + arg parse (~1k gas) — the delta reflects the whole thing.
///           - On LOP, expiry and allowedSender are checked UNCONDITIONALLY for every order (not
///             flag-gated), and the flag is parsed in both the with/without orders, so those cancel in
///             the delta. What's left is only the extra comparison operands the `||`/`&&` short-circuit
///             skips when the flag is zero — literally CALLER+AND+EQ (~8) for private, TIMESTAMP+LT
///             (~7) for expiry. So "LOP expiry ~7 gas" means "enabling it is ~free; LOP already pays the
///             check on the base path", NOT that the check itself is 7 gas.
///           - epoch and interactions ARE flag-gated in LOP (if needCheckEpochManager / needPre*Call),
///             so their deltas are real (epoch = a cold SLOAD; interactions = the external calls).
///
///         This also meters EXECUTION gas only (gasleft around an internal call); it excludes the
///         transaction-level calldata cost (16 gas/nonzero byte) where SwapVM's bytecode-in-calldata
///         programs are far heavier than LOP's compact orders.
///
/// @dev    Only the fill *call* is metered (see LopParityBase.FillResult.gasUsed) — not building/signing.
///         {_runBench} warms the shared paths once (so input #0 isn't a cold outlier), then meters every
///         fill in storage isolation via snapshot/revert, so each order's own slots (invalidator, epoch)
///         are cold exactly like a real first fill.
///
///         Run:  forge test --match-contract LopGasBench -vv
contract LopGasBenchTest is LopParityBase {
    uint256 internal constant SAMPLES = 32;

    /// @dev The functionality each bench isolates. `Baseline` is special — it has no "without", so it
    ///      reports the absolute gas of the simplest order. Every other entry reports a signed delta of
    ///      WITH minus WITHOUT (see {_featureOrders}); for `PartialFill` "without" is the cheaper bit
    ///      invalidator and "with" is the partial-fill (remaining) invalidator, i.e. the extra cost of
    ///      partial-fill bookkeeping over a one-shot order.
    enum Feature {
        Baseline,
        PartialFill,
        Expiry,
        PrivateOrder,
        Epoch,
        Interactions
    }

    /// @dev Whole-order configurations measured as ABSOLUTE gas (like Baseline, but richer) — to see
    ///      what realistic combined orders cost end to end, not just one feature's marginal delta.
    enum Scenario {
        PartialExactIn,          // standard resting limit order, filled by taker amount
        PartialExactOut,         // filled by maker amount
        BitSingleFillExactIn,    // one-shot (RFQ-style) bit-invalidator order
        PartialThresholdExactIn, // + min-output rate protection
        PartialExpiry,           // + expiry
        PartialPrivate,          // + allowedSender
        PartialEpoch,            // + epoch manager
        PartialInteractions,     // + maker pre/post interactions
        KitchenSink              // partial + expiry + private + epoch + threshold + interactions
    }

    // ---- one test per functionality ----------------------------------------------------------------

    function test_GasBench_Baseline() public {
        _runBench("baseline: simplest full-fill order (VM _invalidateBit1D + _limitSwapOnlyFull1D)", Feature.Baseline);
    }

    function test_GasBench_PartialFill() public {
        _runBench("partial-fill invalidator over bit invalidator (VM _invalidateTokenOut1D vs _invalidateBit1D)", Feature.PartialFill);
    }

    function test_GasBench_Expiry() public {
        _runBench("expiry (VM Controls._deadline vs LOP makerTraits expiration)", Feature.Expiry);
    }

    function test_GasBench_PrivateOrder() public {
        _runBench("private order (VM Whitelist._whitelistSingleTaker vs LOP allowedSender)", Feature.PrivateOrder);
    }

    function test_GasBench_Epoch() public {
        _runBench("epoch (VM SeriesEpochManager._validateSeriesEpochXD vs LOP epoch manager)", Feature.Epoch);
    }

    function test_GasBench_Interactions() public {
        _runBench("maker interactions (VM maker hooks vs LOP pre/post-interaction extension)", Feature.Interactions);
    }

    // ---- combined / configuration benchmarks (absolute gas of a whole order) -----------------------

    function test_GasBench_Config_PartialExactIn() public {
        _runConfigBench("config: partial+multiple, exactIn", Scenario.PartialExactIn);
    }

    function test_GasBench_Config_PartialExactOut() public {
        _runConfigBench("config: partial+multiple, exactOut", Scenario.PartialExactOut);
    }

    function test_GasBench_Config_BitSingleFillExactIn() public {
        _runConfigBench("config: one-shot bit invalidator, exactIn (RFQ-style)", Scenario.BitSingleFillExactIn);
    }

    function test_GasBench_Config_PartialThresholdExactIn() public {
        _runConfigBench("config: partial + min-output threshold, exactIn", Scenario.PartialThresholdExactIn);
    }

    function test_GasBench_Config_PartialExpiry() public {
        _runConfigBench("config: partial + expiry, exactIn", Scenario.PartialExpiry);
    }

    function test_GasBench_Config_PartialPrivate() public {
        _runConfigBench("config: partial + private order, exactIn", Scenario.PartialPrivate);
    }

    function test_GasBench_Config_PartialEpoch() public {
        _runConfigBench("config: partial + epoch, exactIn", Scenario.PartialEpoch);
    }

    function test_GasBench_Config_PartialInteractions() public {
        _runConfigBench("config: partial + maker interactions, exactIn", Scenario.PartialInteractions);
    }

    function test_GasBench_Config_KitchenSink() public {
        _runConfigBench("config: kitchen sink (expiry + private + epoch + threshold + interactions)", Scenario.KitchenSink);
    }

    // ---- the benchmark loop ------------------------------------------------------------------------

    function _runBench(string memory label, Feature feature) internal {
        _warmSharedPaths();

        int256[] memory swapVmGas = new int256[](SAMPLES);
        int256[] memory lopGas = new int256[](SAMPLES);

        for (uint256 i = 0; i < SAMPLES; ++i) {
            (uint256 makingAmount, uint256 takingAmount) = _sample(i);
            FillSpec memory fill = _fullFill(takingAmount);

            if (feature == Feature.Baseline) {
                OrderSpec memory simplest = _baseSpec(makingAmount, takingAmount, false, false, 0);
                swapVmGas[i] = int256(_swapVmFillGas(simplest, fill));
                lopGas[i] = int256(_lopFillGas(simplest, fill));
            } else {
                (OrderSpec memory without, OrderSpec memory with) = _featureOrders(feature, makingAmount, takingAmount, i);
                swapVmGas[i] = int256(_swapVmFillGas(with, fill)) - int256(_swapVmFillGas(without, fill));
                lopGas[i] = int256(_lopFillGas(with, fill)) - int256(_lopFillGas(without, fill));
            }
        }

        _report(label, swapVmGas, lopGas);
    }

    /// @dev The (without, with) order pair whose fill-gas difference isolates `feature`. Most features
    ///      toggle one flag on a partial+multiple base; PartialFill instead contrasts the two invalidator
    ///      mechanisms (bit invalidator vs remaining/tokenOut invalidator).
    function _featureOrders(Feature feature, uint256 makingAmount, uint256 takingAmount, uint256 i)
        internal
        view
        returns (OrderSpec memory without, OrderSpec memory with)
    {
        if (feature == Feature.PartialFill) {
            without = _baseSpec(makingAmount, takingAmount, true, false, 0); // single fill  => bit invalidator
            with = _baseSpec(makingAmount, takingAmount, true, true, 0); // partial+multiple => remaining invalidator
            return (without, with);
        }

        without = _baseSpec(makingAmount, takingAmount, true, true, 0);
        with = _baseSpec(makingAmount, takingAmount, true, true, 0);
        if (feature == Feature.Expiry) {
            with.expiry = uint40(BASE_TS + 3600);
        } else if (feature == Feature.PrivateOrder) {
            with.allowedSender = taker; // set to the filler so the order still fills
        } else if (feature == Feature.Epoch) {
            with.needCheckEpoch = true; // series 0 / epoch 0 == the maker's initial epoch => fills
        } else if (feature == Feature.Interactions) {
            with.preInteraction = true;
            with.postInteraction = true;
            with.preInteractionData = abi.encodePacked("pre", i);
            with.postInteractionData = abi.encodePacked("post", i);
        }
    }

    /// @dev Like the baseline, but for an arbitrary whole-order configuration: measures ABSOLUTE fill
    ///      gas of the configured order on each platform (no with/without delta).
    function _runConfigBench(string memory label, Scenario scenario) internal {
        _warmSharedPaths();

        int256[] memory swapVmGas = new int256[](SAMPLES);
        int256[] memory lopGas = new int256[](SAMPLES);

        for (uint256 i = 0; i < SAMPLES; ++i) {
            (uint256 makingAmount, uint256 takingAmount) = _sample(i);
            (OrderSpec memory spec, FillSpec memory fill) = _buildScenario(scenario, makingAmount, takingAmount, i);
            swapVmGas[i] = int256(_swapVmFillGas(spec, fill));
            lopGas[i] = int256(_lopFillGas(spec, fill));
        }

        _report(label, swapVmGas, lopGas);
    }

    /// @dev Build a fully-configured order + fill for `scenario`. Every variant is constructed to fill
    ///      successfully: a full exactIn fill yields output == makingAmount, so a min-output threshold of
    ///      makingAmount passes; epoch 0 / allowedSender == taker / future expiry all hold.
    function _buildScenario(Scenario scenario, uint256 makingAmount, uint256 takingAmount, uint256 i)
        internal
        view
        returns (OrderSpec memory spec, FillSpec memory fill)
    {
        spec = _baseSpec(makingAmount, takingAmount, true, true, 0); // default: partial + multiple
        fill = _fullFill(takingAmount); // default: exactIn over the whole taker side

        if (scenario == Scenario.PartialExactIn) {
            // defaults
        } else if (scenario == Scenario.PartialExactOut) {
            fill = FillSpec({ byMakingAmount: true, amount: makingAmount, hasThreshold: false, threshold: 0 });
        } else if (scenario == Scenario.BitSingleFillExactIn) {
            spec = _baseSpec(makingAmount, takingAmount, true, false, 0); // single fill => bit invalidator
        } else if (scenario == Scenario.PartialThresholdExactIn) {
            fill = FillSpec({ byMakingAmount: false, amount: takingAmount, hasThreshold: true, threshold: makingAmount });
        } else if (scenario == Scenario.PartialExpiry) {
            spec.expiry = uint40(BASE_TS + 3600);
        } else if (scenario == Scenario.PartialPrivate) {
            spec.allowedSender = taker;
        } else if (scenario == Scenario.PartialEpoch) {
            spec.needCheckEpoch = true;
        } else if (scenario == Scenario.PartialInteractions) {
            spec.preInteraction = true;
            spec.postInteraction = true;
            spec.preInteractionData = abi.encodePacked("pre", i);
            spec.postInteractionData = abi.encodePacked("post", i);
        } else if (scenario == Scenario.KitchenSink) {
            spec.expiry = uint40(BASE_TS + 3600);
            spec.allowedSender = taker;
            spec.needCheckEpoch = true;
            spec.preInteraction = true;
            spec.postInteraction = true;
            spec.preInteractionData = abi.encodePacked("pre", i);
            spec.postInteractionData = abi.encodePacked("post", i);
            fill = FillSpec({ byMakingAmount: false, amount: takingAmount, hasThreshold: true, threshold: makingAmount });
        }
    }

    // ---- metering ----------------------------------------------------------------------------------

    /// @dev Gas of one SwapVM fill, metered in storage isolation so per-order slots are cold.
    function _swapVmFillGas(OrderSpec memory order, FillSpec memory fill) internal returns (uint256 gasUsed) {
        uint256 snapshot = vm.snapshotState();
        FillResult memory r = _fillVm(order, fill);
        assertTrue(r.ok, "bench: SwapVM fill must succeed");
        gasUsed = r.gasUsed;
        vm.revertToState(snapshot);
    }

    function _lopFillGas(OrderSpec memory order, FillSpec memory fill) internal returns (uint256 gasUsed) {
        uint256 snapshot = vm.snapshotState();
        FillResult memory r = _fillLop(order, fill);
        assertTrue(r.ok, "bench: LOP fill must succeed");
        gasUsed = r.gasUsed;
        vm.revertToState(snapshot);
    }

    /// @dev Touch the heavy shared paths once so the metered loop is uniformly warm (input #0 included).
    /// @dev Only warms shared infrastructure (tokens, maker, signature, swap math) — deliberately NOT the
    ///      invalidator slots: each metered order must hit a cold invalidator slot like a real first fill,
    ///      and warming the maker's bit-invalidator bucket here would both pollute its SSTORE cost and
    ///      collide with the bit-0 orders the loop fills.
    function _warmSharedPaths() internal {
        FillSpec memory fill = _fullFill(13e18);
        _fillVm(_baseSpec(7e18, 13e18, true, true, 0), fill);
        _fillLop(_baseSpec(7e18, 13e18, true, true, 0), fill);

        OrderSpec memory hooks = _baseSpec(7e18, 13e18, true, true, 0);
        hooks.preInteraction = true;
        hooks.postInteraction = true;
        hooks.preInteractionData = "warm";
        hooks.postInteractionData = "warm";
        _fillVm(hooks, fill);
        _fillLop(hooks, fill);
    }

    // ---- inputs ------------------------------------------------------------------------------------

    /// @dev Deterministic input #i (scripts have no RNG): amounts in [1e12, 1e30) from keccak(i).
    function _sample(uint256 i) internal pure returns (uint256 makingAmount, uint256 takingAmount) {
        uint256 span = 1e30 - 1e12;
        makingAmount = 1e12 + (uint256(keccak256(abi.encode("bench.making", i))) % span);
        takingAmount = 1e12 + (uint256(keccak256(abi.encode("bench.taking", i))) % span);
    }

    /// @dev exactIn over the whole takerAsset side => output == makingAmount, always > 0, always valid.
    function _fullFill(uint256 takingAmount) internal pure returns (FillSpec memory) {
        return FillSpec({ byMakingAmount: false, amount: takingAmount, hasThreshold: false, threshold: 0 });
    }

    // ---- reporting ---------------------------------------------------------------------------------

    function _report(string memory label, int256[] memory swapVmGas, int256[] memory lopGas) internal {
        int256 n = int256(swapVmGas.length);
        int256 sumVm;
        int256 worstVm;
        int256 sumLop;
        int256 worstLop;
        int256 sumDivGas;
        int256 worstDivGas;
        int256 sumDivPct; // basis points
        int256 worstDivPct;

        for (uint256 i = 0; i < swapVmGas.length; ++i) {
            int256 v = swapVmGas[i];
            int256 l = lopGas[i];
            sumVm += v;
            sumLop += l;
            if (i == 0 || v > worstVm) worstVm = v;
            if (i == 0 || l > worstLop) worstLop = l;

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
        emit log(string.concat("  LOP    gas   avg ", vm.toString(sumLop / n), "   worst ", vm.toString(worstLop)));
        emit log(string.concat("  divergence   avg ", vm.toString(sumDivGas / n), " gas / ", _pct(sumDivPct / n)));
        emit log(string.concat("  divergence worst ", vm.toString(worstDivGas), " gas / ", _pct(worstDivPct)));
    }

    /// @dev Signed basis points -> percent with two decimals, e.g. 4027 -> "+40.27%".
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
