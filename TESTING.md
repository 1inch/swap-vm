# Testing Status Report for SwapVM Instructions

## Invariant Tests with TODO Comments

### 1. **ConcentrateXYCDecayFeesInvariants.t.sol**

#### Test: `test_Order1_GrowPriceRange2D`
- Instructions used: `Balances`, `Decay`, `Fee` (progressive), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_Order1_GrowPriceRangeXD`
- Instructions used: `Balances`, `Decay`, `Fee` (flat + progressive), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_Order2_GrowPriceRange2D`
- Instructions used: `Balances`, `Fee` (progressive), `Decay`, `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_Order3_GrowPriceRangeXD`
- Instructions used: `Balances`, `Decay`, `Concentrate` (GrowPriceRange), `Fee` (progressive), `XYC`
- TODO: "why it didn't fail?"

#### Test: `test_Order4_GrowPriceRange2D`
- Instructions used: `Balances`, `Fee` (flat + progressive), `Concentrate` (GrowPriceRange), `Decay`, `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_Order5_GrowPriceRangeXD`
- Instructions used: `Balances`, `Concentrate` (GrowPriceRange), `Decay`, `Fee` (progressive), `XYC`
- TODO: "why it didn't fail?"

#### Test: `test_Order6_GrowPriceRange2D`
- Instructions used: `Balances`, `Concentrate` (GrowPriceRange), `Fee` (protocol + progressive), `Decay`, `XYC`
- TODO: "why it didn't fail?"

#### All tests in this file
- TODO: "need to research behavior" (in `_testInvariantsWithTolerance` method)
- Always skips additivity test

### 2. **DecayXYCFeesInvariants.t.sol**

#### Test: `test_DecayXYCFlatFeeOut`
- Instructions used: `Balances`, `Fee` (flat output), `Decay`, `XYC`
- TODO: "State-dependent due to decay"
- Skips: additivity test

#### Test: `test_DecayXYCProgressiveFeeIn`
- Instructions used: `Balances`, `Fee` (progressive input), `Decay`, `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_DecayXYCProgressiveFeeOut`
- Instructions used: `Balances`, `Fee` (progressive output), `Decay`, `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_DecayXYCProtocolFee`
- Instructions used: `Balances`, `Fee` (protocol), `Decay`, `XYC`
- TODO: "State-dependent due to decay + protocol fees"
- Skips: additivity test

#### Test: `test_DecayXYCMultipleFees`
- Instructions used: `Balances`, `Fee` (flat + progressive), `Decay`, `XYC`
- TODO: "due to progressive fees"
- Skips: additivity test

### 3. **TWAPLimitSwapInvariants.t.sol**

#### Test: `test_TWAPLimitSwapSymmetry`
- Instructions used: `Balances`, `TWAP`, `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: symmetry test

#### Test: `test_TWAPLimitSwapAdditivity`
- Instructions used: `Balances`, `TWAP`, `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: additivity test

#### Test: `test_TWAPLimitSwapMonotonicity`
- Instructions used: `Balances`, `TWAP`, `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: symmetry test

#### Test: `test_TWAPLimitSwapFlatFeeAdditivity`
- Instructions used: `Balances`, `TWAP`, `Fee` (flat), `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: additivity test

#### Test: `test_TWAPLimitSwapProgressiveFeeAdditivity`
- Instructions used: `Balances`, `TWAP`, `Fee` (progressive), `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: additivity test

#### Test: `test_TWAPLimitSwapProtocolFeeAdditivity`
- Instructions used: `Balances`, `TWAP`, `Fee` (protocol), `LimitSwap`
- TODO: "TWAP violates standard invariants due to time and state dependencies"
- Skips: additivity test

### 4. **DutchAuctionLimitSwapFeesInvariants.t.sol**

#### Test: `test_DutchAuctionLimitSwapProgressiveFee`
- Instructions used: `Balances`, `DutchAuction`, `Fee` (progressive), `LimitSwap`
- TODO: "Fix additivity and monotonicity for progressive fees with dutch auction"
- Skips: additivity and monotonicity tests

#### Test: `test_DutchAuctionLimitSwapMultipleFees`
- Instructions used: `Balances`, `DutchAuction`, `Fee` (flat + progressive), `LimitSwap`
- TODO: "Fix additivity for progressive fees with dutch auction"
- Skips: additivity test

#### Test: `test_DutchAuctionLimitSwapProtocolFee`
- Instructions used: `Balances`, `DutchAuction`, `Fee` (protocol), `LimitSwap`
- TODO: "Fix additivity for protocol fees with dutch auction"
- Skips: additivity test

#### Test: `test_DutchAuctionLimitSwapAllFeeTypes`
- Instructions used: `Balances`, `DutchAuction`, `Fee` (flat + progressive + protocol), `LimitSwap`
- TODO: "Fix additivity for progressive fees with dutch auction"
- Skips: additivity test

### 5. **BaseFeeAdjusterFeesInvariants.t.sol**

#### Test: `test_BaseFeeAdjuster_ModerateGas_FlatFee`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (flat), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_ModerateGas_ProgressiveFee`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (progressive), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_ModerateGas_ProtocolFee`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (protocol), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_ModerateGas_MultipleFees`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (flat + progressive), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_ModerateGas_ProtocolAndProgressiveFees`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (protocol + progressive), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_ModerateGas_AllFeeTypes`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (flat + progressive + protocol), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjusterWithDutchAuction_ModerateGas_Fees`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `DutchAuction`, `Fee` (progressive), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjusterWithETH_ModerateGas_Fees`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `DutchAuction`, `Fee` (progressive), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Test: `test_BaseFeeAdjuster_GasSpike_Fees`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `Fee` (flat), `LimitSwap`
- TODO: "BaseFeeAdjuster breaks symmetry and additivity due to asymmetric gas adjustments"
- Skips: symmetry and additivity tests

#### Helper method: `_testInvariantsWithConfigForFees`
- TODO: "Research if additivity can be preserved for gas-adjusted orders with fees"
- TODO: "Research if symmetry can be restored despite asymmetric gas adjustments and fees"
- TODO: "Research monotonicity behavior with progressive fees and gas adjustment"

### 6. **ConcentrateXYCFeesInvariants.t.sol**

#### Test: `test_GrowLiquidity_2D_FlatFeeIn`
- Instructions used: `Balances`, `Fee` (flat input), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "need to research behavior - state-dependent due to scale"
- Skips: additivity test

#### Test: `test_GrowLiquidity_2D_ProgressiveFeeIn`
- Instructions used: `Balances`, `Fee` (progressive input), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_GrowPriceRange_2D_FlatFeeIn`
- Instructions used: `Balances`, `Fee` (flat input), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_GrowLiquidity_XD_FlatFeeOut`
- Instructions used: `Balances`, `Fee` (flat output), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "need to research behavior - state-dependent due to scale"
- Skips: additivity test

#### Test: `test_GrowLiquidity_XD_ProgressiveFeeOut`
- Instructions used: `Balances`, `Fee` (progressive output), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_GrowPriceRange_XD_FlatFeeOut`
- Instructions used: `Balances`, `Fee` (flat output), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_ComplexFeeStructure_GrowLiquidity`
- Instructions used: `Balances`, `Fee` (multiple types), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "Complex fee interactions affect additivity"
- Skips: additivity test

#### Test: `test_GrowLiquidity_2D_ProtocolFee`
- Instructions used: `Balances`, `Fee` (protocol), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "need to research behavior - state-dependent due to scale"
- Skips: additivity test

#### Test: `test_GrowLiquidity_XD_ProgressiveFeeIn`
- Instructions used: `Balances`, `Fee` (progressive input), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_GrowPriceRange_XD_ProgressiveFeeIn`
- Instructions used: `Balances`, `Fee` (progressive input), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_GrowLiquidity_XD_ProtocolFee`
- Instructions used: `Balances`, `Fee` (protocol), `Concentrate` (GrowLiquidity), `XYC`
- TODO: "need to research behavior - state-dependent due to scale"
- Skips: additivity test

#### Test: `test_GrowPriceRange_2D_ProgressiveFeeOut`
- Instructions used: `Balances`, `Fee` (progressive output), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "Progressive fees violate additivity by design"
- Skips: additivity test

#### Test: `test_GrowPriceRange_2D_ProtocolFee`
- Instructions used: `Balances`, `Fee` (protocol), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior"
- Skips: symmetry test

#### Test: `test_ComplexFeeStructure_GrowPriceRange`
- Instructions used: `Balances`, `Fee` (multiple types), `Concentrate` (GrowPriceRange), `XYC`
- TODO: "need to research behavior - state-dependent due to scale"
- Skips: additivity test

### 7. **BaseFeeAdjusterInvariants.t.sol**

#### Test: `test_BaseFeeAdjuster_ModerateGasPrice`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `LimitSwap`
- TODO: "research invariant behavior at moderate gas prices"

#### Test: `test_BaseFeeAdjuster_HighGasPrice`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `LimitSwap`
- TODO: "research invariant behavior at high gas prices"

#### Test: `test_BaseFeeAdjusterWithETH_VariousPrices`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `LimitSwap`
- TODO: "Analyze invariant behavior across different ETH prices"

#### Test: `test_BaseFeeAdjusterWithDutchAuction_ModerateGas`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `DutchAuction`, `LimitSwap`
- TODO: "Analyze invariant behavior with DutchAuction and gas adjustment"

#### Test: `test_BaseFeeAdjusterWithDutchAuctionOutput_ModerateGas`
- Instructions used: `Balances`, `BaseFeeAdjuster`, `DutchAuction` (output), `LimitSwap`
- TODO: "Analyze invariant behavior with DutchAuction output and gas adjustment"
