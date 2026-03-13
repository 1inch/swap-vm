# SwapVM Programs Catalog

This document catalogs different kinds of SwapVM programs, their typical instruction composition, and expected behavior.

---

> **Important Notice:** 1inch production integrations (including AggregationRouter flows) will use only a strict, predefined subset of SwapVM programs with tightly bounded parameter ranges and completed security reviews. Risk from interacting with arbitrary or maliciously crafted SwapVM programs remains with the taker/resolver choosing to execute them.

In line with the notice above, follow these recommendations when building SwapVM programs:

- Provide analytical proof (or strong formal/empirical evidence) of model stability; public notes or papers are encouraged.
- Constrain dangerous parameter ranges in instruction builders to prevent unsafe program construction.
- Provide a thorough composition guide when your design supports multiple instruction-order variants.

## Purpose of this document

- Provide a reference for program patterns used in SwapVM.
- Describe when to use each program type.
- Document instruction sequences and ordering constraints.
- Capture security notes and invariant expectations per program type.

---

## SwapVM Program Key Points

When designing a SwapVM program, we focus on these security-critical technical points:

- **Balance mode and use case:**
  - **Static balances (`_staticBalancesXD`)**: fixed-rate, stateless execution; typically used for 1D strategies (limit orders, auctions, RFQ-like flows).
  - **Dynamic balances (`_dynamicBalancesXD`)**: stateful reserves updated across swaps; typically used for 2D AMM strategies.
  - **Aqua-backed mode (`useAquaInsteadOfSignature = true`)**: balances are sourced/settled via Aqua instead of signature-based local state.
- **Instruction ordering is security-critical:**
  - Reordering instructions can change pricing, settlement amounts, invalidation behavior, and external side effects.
  - Fee instruction placement is especially sensitive and can alter economic outcomes.
- **Invariant requirements must hold for the full composed program:**
  - Symmetry, additivity profile, monotonicity, quote/swap consistency, balance sufficiency, and strategy liveness.
  - Validate invariants with scenario tests before production deployment.

**Thorough testing and audit are mandatory for every program before production use.**  

You can use these invariant suites as references for testing your programs:

- **1D strategy reference tests:** [`test/invariants/DutchAuctionLimitSwapInvariants.t.sol`](../test/invariants/DutchAuctionLimitSwapInvariants.t.sol)
- **2D strategy reference tests:** [`test/invariants/ConcentrateXYCInvariants.t.sol`](../test/invariants/ConcentrateXYCInvariants.t.sol)

---

## Catalog

### 1) Limit Order Programs (1D, static balances)

- **Intent:** Fixed-rate one-direction swaps with optional partial fills.
- **Required Core:**
  - `Balances._staticBalancesXD`
  - `LimitSwap._limitSwap1D` or `LimitSwap._limitSwapOnlyFull1D`
- **Common Add-ons:**
  - `Invalidators._invalidateBit1D`
  - `Invalidators._invalidateTokenIn1D` / `Invalidators._invalidateTokenOut1D`
  - `DutchAuction._dutchAuctionBalanceIn1D` / `_dutchAuctionBalanceOut1D`
  - `BaseFeeAdjuster._baseFeeAdjuster1D`
  - `MinRate._requireMinRate1D` / `_adjustMinRate1D`
  - `TWAPSwap._twap`

**Example A - One-time limit order (bitmap invalidator):**

Use case: one-shot maker quote that must execute at most once.  
Analog: RFQ/limit-order style flow (not a pool AMM).  
Difference note: SwapVM composes this behavior via instruction ordering and invalidators, so execution/fee behavior can differ from traditional order protocols.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(123)), // One-time replay protection
    program.build(_staticBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenA, tokenB]),
        dynamic([uint256(1000e18), uint256(2000e18)])
    )), // Set fixed-rate balances for 1D swap
    program.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenA, tokenB)) // Compute limit-order amounts
);
```

**Example B - Partial-fill limit order (token-out invalidator):**

Use case: fixed-rate quote that can be filled over multiple swaps until exhausted.  
Analog: partially fillable limit-order systems.  
Difference note: partial-fill accounting is instruction-driven (`_invalidateTokenOut1D`) and can differ from external orderbook accounting models.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_staticBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenA, tokenB]),
        dynamic([uint256(1000e18), uint256(2000e18)])
    )), // Set fixed-rate balances for 1D swap
    program.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenA, tokenB)), // Compute limit-order amounts
    program.build(_invalidateTokenOut1D) // Track cumulative output for partial fills
);
```

**Invariant Focus (Limit Order Programs):**
- Quote/swap consistency under exact-in and exact-out flows.
- Threshold and min-rate correctness for protected fills.
- Invalidation correctness (no replay, no overfill, deterministic partial-fill accounting).
- Balance sufficiency and rounding behavior near small/dust amounts.

### 2) AMM Programs (2D, dynamic balances)

- **Intent:** Stateful bidirectional liquidity strategies.
- **Required Core:**
  - Dynamic balance initialization
  - One primary AMM primitive:
    - `XYCSwap._xycSwapXD`
    - `PeggedSwap._peggedSwapGrowPriceRange2D`
    - `XYCConcentrate._xycConcentrateGrowLiquidity2D`
    - `XYCConcentrateExperimental._xycConcentrateGrowPriceRange2D`
- **Common Add-ons:**
  - Fee instructions (flat/progressive/protocol/dynamic-protocol variants)
  - `Decay._decayXD`
  - `TWAPSwap._twap`
  - Control flow instructions (`_jump`, `_jumpIfTokenIn`, `_jumpIfTokenOut`, `_deadline`, `_salt`, ...)
- **Ordering Note:** Fee instruction placement is security-critical and changes pricing/settlement behavior.

**Example A - XYCSwap AMM:**

Use case: generic constant-product AMM curve for volatile pairs.  
Analog: Uniswap V2-style `x*y=k` pool.  
Difference note: SwapVM uses composable VM instructions, so fee layering and exact internal math may differ from canonical Uniswap V2 implementations.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenA, tokenB]),
        dynamic([uint256(1_000e18), uint256(1_000e18)])
    )), // Initialize AMM reserves in dynamic storage
    program.build(_xycSwapXD) // Apply x*y=k swap pricing
);
```

**Example B - Concentrated liquidity (2D bounds + swap):**

Use case: liquidity concentrated into a bounded price range for capital efficiency.  
Analog: Uniswap V3-style concentrated liquidity behavior.  
Difference note: price-range logic and fee composition are implemented through SwapVM instructions and can differ from Uniswap V3 internals/math details.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenLt, tokenGt]),
        dynamic([uint256(1_000e18), uint256(1_000e18)])
    )), // Initialize AMM reserves in dynamic storage
    program.build(_xycConcentrateGrowLiquidity2D, XYCConcentrateArgsBuilder.build2D(
        sqrtPriceMin,
        sqrtPriceMax
    )), // Apply concentrated-liquidity bounds
    program.build(_xycSwapXD) // Execute swap using concentrated state
);
```

**Example C - PeggedSwap AMM (pegged assets):**

Use case: low-slippage swapping for correlated/pegged assets.  
Analog: Curve StableSwap-style behavior.  
Difference note: SwapVM pegged math and fee integration are not byte-for-byte Curve StableSwap and may produce different edge-case behavior.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenLt, tokenGt]),
        dynamic([uint256(1_000e18), uint256(1_000e18)])
    )), // Initialize AMM reserves in dynamic storage
    program.build(_peggedSwapGrowPriceRange2D, PeggedSwapArgsBuilder.build(
        PeggedSwapArgsBuilder.Args({
            x0: x0,
            y0: y0,
            linearWidth: linearWidth,
            rateLt: rateLt,
            rateGt: rateGt
        })
    )) // Execute peggedswap-style pricing step
);
```

**Example D - Decay-enhanced AMM:**

Use case: AMM with virtual-balance decay for MEV/frontrun resistance.  
Analog: Mooniswap-style virtual balances/decay behavior.  
Difference note: decay is composed as a dedicated instruction with SwapVM-specific interaction with fees and swap primitives.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenA, tokenB]),
        dynamic([uint256(1_000e18), uint256(1_000e18)])
    )), // Initialize AMM reserves in dynamic storage
    program.build(_decayXD, DecayArgsBuilder.build(300)), // Apply virtual-balance decay offset
    program.build(_xycSwapXD) // Execute swap with decay-adjusted state
);
```

**Invariant Focus (AMM Programs):**
- Exact in/out symmetry across representative trade sizes.
- Additivity profile (strict/additive/subadditive target depending on strategy design).
- Monotonicity (larger trades should not get better effective price unless explicitly intended).
- Strategy liveness when one side is depleted (reverse swaps should restore operability where applicable).
- Fee-placement correctness and quote/swap consistency with composed fee instructions.

### 3) Aqua-backed Programs

- **Intent:** Use Aqua as balance source/settlement layer with the same VM logic.
- **Setup Trait:** `useAquaInsteadOfSignature = true`
- **Maker Liquidity Model:** Funds can be used on demand from Aqua balances, so makers do not need to lock isolated liquidity per strategy.
- **Multi-Strategy Usage:** The same Aqua-backed liquidity can be reused across multiple different strategies at the same time.
- **Differences vs non-Aqua:**
  - Authorization and balance source differ (Aqua balance mode vs signature mode).
  - `useAquaInsteadOfSignature` changes settlement/auth flow, not VM strategy composition itself.
  - Core AMM or limit instruction logic can remain the same.
- **Important:** SwapVM strategy composition works both with Aqua-backed settlement and without Aqua (signature-based mode).


### 4) SwapVM Programs with Conditional Flow

- **Intent:** Add runtime branching (gating, route selection, or dynamic control flow) based on swap context or external logic.
- **Key Risk:** Branching can introduce hidden execution paths that are hard to reason about and easy to misconfigure.

**Example A - Permissioned swap by taker balance (institutional gate):**

Use case: allow execution only for takers that hold a required token/NFT balance.

```solidity
Program memory program = ProgramBuilder.init(_opcodes());
bytes memory bytecode = bytes.concat(
    // Gate: taker must hold gateToken (or NFT) balance > 0
    program.build(_onlyTakerTokenBalanceNonZero,
        ControlsArgsBuilder.buildTakerTokenBalanceNonZero(gateToken)), // Restrict execution to eligible takers
    // Regular limit-order path
    program.build(_staticBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenIn, tokenOut]),
        dynamic([uint256(1_000e18), uint256(2_000e18)])
    )), // Set fixed-rate balances for 1D swap
    program.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut)) // Compute limit-order amounts
);
```

**Example B - Best strategy selection (XYC vs Pegged):**

Use case: evaluate multiple AMM strategy branches and execute the one that gives better output for current conditions.  
Reference: `test/RunLoop.t.sol` (`test_BestRouteSelector_XYC_vs_Pegged`).

```solidity
Program memory program = ProgramBuilder.init(_opcodes());

bytes memory strategy1 = program.build(_xycSwapXD); // Branch A: x*y=k swap
bytes memory strategy2 = program.build(
    _peggedSwapGrowPriceRange2D,
    PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
        x0: 50e18,
        y0: 50e18,
        linearWidth: 0.02e9,
        rateLt: 1,
        rateGt: 1
    }))
); // Branch B: pegged-curve swap

bytes memory selectorArgs = abi.encodePacked(
    address(bestRouteSelectorTarget), // External selector contract
    uint8(2),                         // Number of branches
    uint16(strategy1.length), strategy1,
    uint16(strategy2.length), strategy2
); // Packed branch bytecodes

bytes memory bytecode = bytes.concat(
    program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
        dynamic([tokenA, tokenB]),
        dynamic([uint256(100e18), uint256(100e18)])
    )), // Initialize shared reserves
    program.build(_extruction, selectorArgs) // Delegate to selector and run best branch
);
```

Complex scenarios with conditional jumps/branching (and, especially, containing ```_extruction```) should be tested very carefully; they can contain hidden logical flaws and unsafe edge paths.

**Invariant Focus (Conditional-Flow Programs):**
- Branch determinism and quote/swap path consistency (same inputs -> same branch).
- Jump-target correctness (no invalid offsets, no accidental instruction skipping/corruption).
- Authorization/gating correctness (restricted users fail, authorized users pass as intended).
- Economic safety across all branches (no branch yields unintended favorable pricing or bypasses checks).
- Termination/liveness: no hidden loops or dead-end paths that break execution.

