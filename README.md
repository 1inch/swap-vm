# SwapVM

[![Github Release](https://img.shields.io/github/v/tag/1inch/swap-vm?sort=semver&label=github)](https://github.com/1inch/swap-vm/releases/latest)
[![CI](https://github.com/1inch/swap-vm/actions/workflows/ci.yml/badge.svg)](https://github.com/1inch/swap-vm/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/Coverage-85%25-green)](https://github.com/1inch/swap-vm)
[![Tests](https://img.shields.io/github/actions/workflow/status/1inch/swap-vm/ci.yml?branch=main&label=tests)](https://github.com/1inch/swap-vm/actions)
[![npm](https://img.shields.io/npm/v/@1inch/swap-vm.svg)](https://www.npmjs.com/package/@1inch/swap-vm)
[![License](https://img.shields.io/badge/License-Degensoft--SwapVM--1.1-orange)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-blue)](https://docs.soliditylang.org/en/v0.8.30/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)

**A virtual machine for programmable token swaps.** Execute complex trading strategies from bytecode programs without deploying contracts.

---

## 📚 Table of Contents

- [Overview](#overview)
- [Deployment](#-deployment)
- [How It Works](#how-it-works)
- [For Makers (Liquidity Providers)](#-for-makers-liquidity-providers)
- [For Takers (Swap Executors)](#-for-takers-swap-executors)
- [For Developers](#-for-developers)
- [Security Model](#-security-model)
- [Advanced Topics](#-advanced-topics)
  - [AMM Instruction Ordering (Canonical)](#amm-instruction-ordering-canonical)

---

## Overview

### What is SwapVM?

SwapVM is a **computation engine** that executes token swap strategies from bytecode programs. Instead of deploying smart contracts, you compose instructions into programs that are signed off-chain and executed on-demand.

**Key Features:**
- **Static Balances** - Fixed exchange rates for single-direction trades (limit orders, auctions, TWAP, DCA, RFQ)
- **Dynamic Balances** - Persistent, isolated AMM-style orders (each maker's liquidity is separate)
- **Composable Instructions** - Mix and match building blocks for complex strategies (combining pricing, fees, MEV protection)

### Who is this for?

- **🌾 Makers** - Provide liquidity through limit orders, AMM-style orders, or complex strategies
- **🏃 Takers** - Execute swaps to arbitrage or fulfill trades
- **🛠 Developers** - Build custom instructions and integrate SwapVM

---

## 🌐 Deployment

SwapVM is deployed across multiple chains with a unified address for seamless cross-chain integration.

**Contract Address:** `0x8fdd04dbf6111437b44bbca99c28882434e0958f`

**Supported Networks:**
- Ethereum Mainnet
- Base
- Optimism
- Polygon
- Arbitrum
- Avalanche
- Binance Smart Chain
- Linea
- Sonic
- Unichain
- Gnosis
- zkSync

---

## How It Works

### The 4-Register Model

SwapVM uses **4 registers** to compute token swaps:

```
┌────────────────────────────────────────────────────────────┐
│                    SwapRegisters                           │
├────────────────────────────────────────────────────────────┤
│  balanceIn:  Maker's available input token balance         │
│  balanceOut: Maker's available output token balance        │
│  amountIn:   Input amount (taker provides OR VM computes)  │
│  amountOut:  Output amount (taker provides OR VM computes) │
└────────────────────────────────────────────────────────────┘
```

**The Core Principle:**
1. **Taker specifies ONE amount** (either `amountIn` or `amountOut`)
2. **VM computes the OTHER amount** using the 4 registers
3. **Instructions modify registers** to apply fees, adjust rates, etc.

### Execution Flow

The execution flow shows all available instructions and strategies for each balance type:

```
┌──────────────────────────────────────────────────────────┐
│      1D STRATEGY (Static Balances, Single Direction)     │
├──────────────────────────────────────────────────────────┤
│ BYTECODE COMPOSITION (Off-chain)                         │
│                                                          │
│ 1. Balance Setup (Required)                              │
│    └─ _staticBalancesXD → Fixed exchange rate            │
│                                                          │
│ 2. Core Swap Logic (Choose One)                          │
│    ├─ _limitSwap1D → Partial fills allowed               │
│    └─ _limitSwapOnlyFull1D → All-or-nothing              │
│                                                          │
│ 3. Order Invalidation (Required for Partial Fills)       │
│    ├─ _invalidateBit1D → One-time order                  │
│    ├─ _invalidateTokenIn1D → Track input consumed        │
│    └─ _invalidateTokenOut1D → Track output distributed   │
│                                                          │
│ 4. Dynamic Pricing (Optional, Combinable)                │
│    ├─ _dutchAuctionBalanceIn1D → Decreasing input amount  │
│    ├─ _dutchAuctionBalanceOut1D → Increasing output amount│
│    ├─ _oraclePriceAdjuster1D → External price feed       │
│    └─ _baseFeeAdjuster1D → Gas-responsive pricing        │
│                                                          │
│ 5. Fee Mechanisms (Optional, Combinable)                 │
│    ├─ _flatFeeAmountInXD → Fee from input amount         │
│    ├─ _flatFeeAmountOutXD → Fee from output amount       │
│    ├─ _progressiveFeeInXD → Size-based dynamic fee (input)│
│    ├─ _progressiveFeeOutXD → Size-based dynamic fee (output)│
│    ├─ _protocolFeeAmountOutXD → Protocol revenue (ERC20) │
│    ├─ _aquaProtocolFeeAmountOutXD → Protocol revenue (Aqua)│
│    ├─ _dynamicProtocolFeeAmountInXD → Dynamic fee via provider│
│    └─ _aquaDynamicProtocolFeeAmountInXD → Dynamic Aqua fee│
│                                                          │
│ 6. Advanced Strategies (Optional)                        │
│    ├─ _requireMinRate1D → Enforce minimum exchange rate  │
│    ├─ _adjustMinRate1D → Adjust amounts to meet min rate │
│    ├─ _twap → Time-weighted average price execution      │
│    └─ _extruction → Extract and execute custom logic     │
│                                                          │
│ 7. Control Flow (Optional)                               │
│    ├─ _jump → Skip instructions                          │
│    ├─ _jumpIfTokenIn → Conditional on exact input        │
│    ├─ _jumpIfTokenOut → Conditional on exact output      │
│    ├─ _deadline → Expiration check                       │
│    ├─ _onlyTakerTokenBalanceNonZero → Require balance > 0│
│    ├─ _onlyTakerTokenBalanceGte → Minimum balance check  │
│    ├─ _onlyTakerTokenSupplyShareGte → Min % of supply   │
│    └─ _salt → Order uniqueness (hash modifier)           │
│                                                          │
│ EXECUTION (On-chain)                                     │
│ ├─ Verify signature & expiration                         │
│ ├─ Load static balances into 4 registers                 │
│ ├─ Execute bytecode instructions sequentially            │
│ ├─ Update invalidator state (prevent replay/overfill)    │
│ └─ Transfer tokens (single direction only)               │
└──────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  AMM STRATEGIES (2D/XD Bidirectional, Two Balance Options) │
├────────────────────────────────────────────────────────────┤
│ BALANCE MANAGEMENT OPTIONS                                 │
│                                                            │
│ Option A: Dynamic Balances (SwapVM Internal)               │
│    ├─ Setup: Sign order with EIP-712                       │
│    ├─ Balance Instruction: _dynamicBalancesXD              │
│    └─ Storage: SwapVM contract (self-managed)              │
│                                                            │
│ Option B: Aqua Protocol (External)                         │
│    ├─ Setup: Deposit via Aqua.ship() (on-chain)            │
│    ├─ Balance Instruction: None (Aqua manages)             │
│    ├─ Configuration: useAquaInsteadOfSignature = true      │
│    └─ Storage: Aqua protocol (shared liquidity)            │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ BYTECODE COMPOSITION (Same for Both)                       │
│                                                            │
│ 1. Balance Setup                                           │
│    ├─ Dynamic: _dynamicBalancesXD (required)               │
│    └─ Aqua: Skip (balances in Aqua)                        │
│                                                            │
│ 2. AMM Logic (Choose Primary Strategy)                     │
│    ├─ _xycSwapXD → Classic x*y=k constant product          │
│    ├─ _peggedSwapGrowPriceRange2D → Curve for pegged assets│
│    └─ _xycConcentrateGrowLiquidityXD/2D → CLMM ranges      │
│                                                            │
│ 3. Fee Mechanisms (Optional, Combinable)                   │
│    ├─ _flatFeeAmountInXD → Fee from input amount           │
│    ├─ _flatFeeAmountOutXD → Fee from output amount         │
│    ├─ _progressiveFeeInXD → Size-based dynamic fee (input) │
│    ├─ _progressiveFeeOutXD → Size-based dynamic fee (output)│
│    ├─ _protocolFeeAmountOutXD → Protocol revenue (ERC20)   │
│    ├─ _aquaProtocolFeeAmountOutXD → Protocol revenue (Aqua)│
│    ├─ _dynamicProtocolFeeAmountInXD → Dynamic fee via provider│
│    └─ _aquaDynamicProtocolFeeAmountInXD → Dynamic Aqua fee │
│                                                            │
│ 4. MEV Protection (Optional)                               │
│    └─ _decayXD → Virtual reserves (Mooniswap-style)        │
│                                                            │
│ 5. Advanced Features (Optional)                            │
│    ├─ _twap → Time-weighted average price trading          │
│    └─ _extruction → Extract and execute custom logic       │
│                                                            │
│ 6. Control Flow (Optional)                                 │
│    ├─ _jump → Skip instructions                            │
│    ├─ _jumpIfTokenIn → Conditional jump on exact input     │
│    ├─ _jumpIfTokenOut → Conditional jump on exact output   │
│    ├─ _deadline → Expiration check                         │
│    ├─ _onlyTakerTokenBalanceNonZero → Require balance > 0  │
│    ├─ _onlyTakerTokenBalanceGte → Minimum balance check    │
│    ├─ _onlyTakerTokenSupplyShareGte → Min % of supply     │
│    └─ _salt → Order uniqueness (hash modifier)             │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ EXECUTION (On-chain)                                       │
│                                                            │
│ Dynamic Balances Flow:                                     │
│ ├─ Verify EIP-712 signature                                │
│ ├─ Load maker's isolated reserves from SwapVM              │
│ ├─ Execute AMM calculations                                │
│ ├─ Update maker's state in SwapVM storage                  │
│ └─ Transfer tokens (bidirectional)                         │
│                                                            │
│ Aqua Protocol Flow:                                        │
│ ├─ Verify Aqua balance (no signature)                      │
│ ├─ Load reserves from Aqua protocol                        │
│ ├─ Execute AMM calculations (same logic!)                  │
│ ├─ Aqua updates balance accounting                         │
│ └─ Transfer tokens via Aqua settlement                     │
└────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│           COMMON TAKER FLOW (All Strategies)            │
├─────────────────────────────────────────────────────────┤
│ 1. Discovery (Off-chain)                                │
│    ├─ Find orders via indexer/API                       │
│    ├─ Filter by tokens, rates, liquidity                │
│    └─ Simulate profitability                            │
│                                                         │
│ 2. Quote (On-chain View)                                │
│    ├─ Call quote() to preview exact amounts             │
│    ├─ Check slippage and fees                           │
│    └─ Verify execution conditions                       │
│                                                         │
│ 3. Execution Parameters                                 │
│    ├─ isExactIn → Specify input or output amount        │
│    ├─ threshold → Minimum/maximum acceptable amount     │
│    ├─ to → Recipient address                            │
│    └─ hooks → Pre/post swap callbacks                   │
│                                                         │
│ 4. Settlement                                           │
│    ├─ Maker → Taker (output token)                      │
│    └─ Taker → Maker (input token)                       │
└─────────────────────────────────────────────────────────┘
```

### Bytecode Format

Programs are sequences of instructions, each encoded as:

```
[opcode_index][args_length][args_data]
     ↑            ↑            ↑
  1 byte       1 byte      N bytes
```

**Example:** A limit order might compile to:
```
[17][4A][balance_args][26][01][swap_args]
  ↑                      ↑
  staticBalances        limitSwap
```

### Balance Types Explained

SwapVM offers two primary balance management approaches:

#### Static Balances (Single-Direction Trading)
**Use Case:** Limit orders, Dutch auctions, TWAP, DCA, RFQ, range orders, stop-loss
- **Fixed Rate:** Exchange rate remains constant
- **Partial Fills:** Supports partial execution with amount invalidators  
- **No Storage:** Pure function, no state persistence
- **Direction:** Single-direction trades (e.g., only sell ETH for USDC)

```solidity
// Example: Sell 1 ETH for 2000 USDC
p.build(Balances._staticBalancesXD,
    BalancesArgsBuilder.build(
        dynamic([WETH, USDC]),
        dynamic([1e18, 2000e6])  // Fixed rate
    ))
```

#### Dynamic Balances (Automated Market Making)
**Use Case:** Constant product AMMs, CLMMs
- **Self-Rebalancing:** Balances update after each trade
- **State Persistence:** Order state stored in SwapVM
- **Isolated Liquidity:** Each maker's funds are separate (no pooling)
- **Bidirectional:** Supports trading in both directions
- **Price Discovery:** Price adjusts based on reserves

```solidity
// Example: Initialize AMM-style order with 10 ETH and 20,000 USDC
p.build(Balances._dynamicBalancesXD,
    BalancesArgsBuilder.build(
        dynamic([WETH, USDC]),
        dynamic([10e18, 20_000e6])  // Initial reserves
    ))
```

---

## Core Invariants

SwapVM maintains fundamental invariants that ensure economic security and predictable behavior across all instructions:

### 1. Exact In/Out Symmetry
Every instruction MUST maintain symmetry between exactIn and exactOut swaps:
- If `exactIn(X) → Y`, then `exactOut(Y) → X` (within rounding tolerance)
- Critical for price consistency and preventing internal arbitrage
- Validated by test suite across all swap instructions

### 2. Swap Additivity
Splitting swaps must not provide better rates:
- `swap(A+B)` should equal `swap(A) + swap(B)` for output amounts
- Ensures no gaming through order splitting
- Larger trades cannot be improved by breaking into smaller ones

### 3. Quote/Swap Consistency

**Numerical Consistency Guarantee:**
- `quote()` and `swap()` return identical `(amountIn, amountOut)` **if both succeed**
- This ensures predictable execution and prevents quote-execution arbitrage
- Essential for MEV protection and reliable off-chain quoting

**Execution Divergence via `isStaticContext`:**

SwapVM uses `ctx.vm.isStaticContext` to enable gas-free quote previews by conditionally skipping side effects:

| Instruction Category | Quote Mode (`isStaticContext=true`) | Swap Mode (`isStaticContext=false`) |
|---------------------|-----------------------------------|-----------------------------------|
| **Protocol Fees** | Computes fee, skips token transfer | Computes fee, executes token transfer |
| **Invalidators** | Checks limits, skips state update | Checks limits, updates state (prevents replay) |
| **Dynamic Balances** | Reads balances, skips storage write | Reads balances, updates storage |
| **Decay/TWAP** | Uses current state, skips time update | Uses current state, updates timestamp |

**Legitimate Divergence Cases:**
1. ✅ **Quote succeeds, swap reverts** - Missing balance/approval for protocol fee transfer
2. ✅ **Quote succeeds, swap reverts** - Order already executed (invalidator state changed between calls)
3. ✅ **Quote succeeds, swap reverts** - Insufficient remaining balance (partial fill exhausted)

These cases preserve **numerical consistency** (amounts match when both succeed) while allowing execution to fail due to external conditions.

**Problematic Patterns (Maker Responsibility):**
- ❌ **Backward jumps to stateful instructions** - Can break numerical consistency (quote and swap compute different amounts)
- ❌ **Control flow depending on same-execution state changes** - Violates the invariant

**Best Practices:**
- **Makers:** Avoid backward jumps to `isStaticContext`-dependent instructions; test strategies with both `quote()` and `swap()`
- **Takers:** Always use threshold protection in TakerTraits; handle swap revert scenarios even after successful quote
- **Integrations:** Never rely on quote success as guarantee of swap success; use on-chain `quote()` for accurate amounts

### 4. Price Monotonicity
Larger trades receive equal or worse prices:
- Price defined as `amountOut/amountIn` 
- Must decrease (or stay constant) as trade size increases
- Natural consequence of liquidity curves and market impact

### 5. Rounding Favors Maker
All rounding operations must favor the liquidity provider:
- Small trades (few wei) shouldn't exceed theoretical spot price
- `amountIn` always rounds UP (ceil)
- `amountOut` always rounds DOWN (floor)
- Protects makers from rounding-based value extraction

### 6. Balance Sufficiency
Trades cannot exceed available liquidity:
- Must revert if computed `amountOut > balanceOut`
- Prevents impossible trades and protects order integrity
- Enforced at the VM level before token transfers

These invariants are validated through comprehensive test suites and must be maintained by any new instruction implementations.

### Testing Invariants in Your Code

SwapVM provides a reusable `CoreInvariants` base contract for testing:

```solidity
import { CoreInvariants } from "test/invariants/CoreInvariants.t.sol";

contract MyInstructionTest is Test, OpcodesDebug, CoreInvariants {
    function test_MyInstruction_MaintainsInvariants() public {
        // Create order with your instruction
        ISwapVM.Order memory order = createOrderWithMyInstruction();
        
        // Test all invariants at once
        assertAllInvariants(swapVM, order, tokenIn, tokenOut);
        
        // Or test specific invariants
        assertSymmetryInvariant(swapVM, order, tokenIn, tokenOut, 
            amount, tolerance, exactInData, exactOutData);
        assertMonotonicityInvariant(swapVM, order, tokenIn, tokenOut, 
            amounts, takerData);
    }
}
```

Configuration options for complex scenarios:
```solidity
InvariantConfig memory config = createInvariantConfig(testAmounts, tolerance);
config.skipAdditivity = true;    // For stateless orders
config.skipMonotonicity = true;  // For fixed-rate orders
assertAllInvariantsWithConfig(swapVM, order, tokenIn, tokenOut, config);
```

See `test/invariants/ExampleInvariantUsage.t.sol` for complete examples.

---

## 🌾 For Makers (Liquidity Providers)

Makers provide liquidity by creating orders with custom swap logic.

### Your Role

- **Define swap logic** via bytecode programs (includes setting balances/exchange rate)
- **Configure order parameters** (expiration, fees, hooks)
- **Sign orders** off-chain (gasless)

### Creating a Simple Limit Order

```solidity
// 1. Build your swap program
Program memory p = ProgramBuilder.init(_opcodes());
bytes memory program = bytes.concat(
    // Set your exchange rate: 1000 USDC for 0.5 WETH
    p.build(Balances._staticBalancesXD,
        BalancesArgsBuilder.build(
            dynamic([USDC, WETH]),
            dynamic([1000e6, 0.5e18])  // Your offered rate
        )),
    // Execute the swap
    p.build(LimitSwap._limitSwap1D,
        LimitSwapArgsBuilder.build(USDC, WETH)),
    // Track partial fills (prevents overfilling)
    p.build(Invalidators._invalidateTokenOut1D,
        InvalidatorsArgsBuilder.buildInvalidateByTokenOut(WETH))
);

// 2. Configure order parameters
ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
    maker: yourAddress,              // Your address
    receiver: address(0),            // You receive the tokens (0 = maker)
    shouldUnwrapWeth: false,         // Keep WETH (don't unwrap to ETH)
    useAquaInsteadOfSignature: false, // Use standard EIP-712 signing
    allowZeroAmountIn: false,        // Require non-zero input
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
    program: program                 // Your swap program
}));

// 3. Sign order off-chain (gasless)
bytes32 orderHash = swapVM.hash(order);
bytes memory signature = signEIP712(orderHash);
```

### Building an AMM Strategy

Create a persistent, isolated AMM-style order (your liquidity only):

```solidity
// Constant product AMM with 0.3% fee
bytes memory program = bytes.concat(
    // Load/initialize balances
    p.build(Balances._dynamicBalancesXD,
        BalancesArgsBuilder.build(
            dynamic([USDC, WETH]),
            dynamic([100_000e6, 50e18])  // Initial liquidity
        )),
    // Apply trading fee
    p.build(Fee._flatFeeAmountInXD, 
        FeeArgsBuilder.buildFlatFee(0.003e9)),  // 0.3%
    // Execute constant product swap (x*y=k)
    p.build(XYCSwap._xycSwapXD)
);
```

### Strategy Hash Uniqueness and Token Safety

> **⚠️ CRITICAL SECURITY NOTICE FOR MAKERS**
> 
> Strategies must ensure unique orderHash to prevent unintended cross-strategy token access. Always include balance instructions and use `_salt` when needed.

#### Understanding orderHash Generation

For non-Aqua (signature-based) strategies:
```solidity
orderHash = _hashTypedDataV4(keccak256(abi.encode(
    ORDER_TYPEHASH,
    order.maker,
    order.traits,
    keccak256(order.data)  // Contains program bytecode (should include tokens list)
)));
```
For Aqua strategies:
```solidity
orderHash = keccak256(abi.encode(order))
```

#### Required Safety Measures

**1. Always Include Balance Instructions for non-Aqua strategies** (MANDATORY)

Balance instructions (`_staticBalancesXD` or `_dynamicBalancesXD`) encode token addresses directly into your program, tying approved tokens to specific strategies.

```solidity
// ✅ SAFE - Tokens are encoded in program
bytes memory program = bytes.concat(
    p.build(Balances._staticBalancesXD,
        BalancesArgsBuilder.build(
            dynamic([USDC, WETH]),      // Tokens locked to this strategy
            dynamic([1000e6, 0.5e18])
        )),
    p.build(LimitSwap._limitSwap1D, ...),
    p.build(Controls._salt, abi.encodePacked(uint256(1)))  // Unique ID
);

// ❌ UNSAFE - No token validation!
bytes memory program = bytes.concat(
    p.build(LimitSwap._limitSwap1D, ...)  // Taker can choose ANY tokens!
);
```

**2. Use `_salt` for Multiple Similar Strategies**

If you create multiple strategies with identical instructions and parameters, add `_salt` with unique values:

```solidity
// Strategy A
p.build(Controls._salt, abi.encodePacked(uint256(1)))

// Strategy B (same instructions but different salt)
p.build(Controls._salt, abi.encodePacked(uint256(2)))
```

Without `_salt`, identical programs generate the same `orderHash`, causing:
- Shared storage state (one strategy affects the other)
- Inability to run multiple identical strategies simultaneously
- Potential accounting conflicts

**3. Custom Accounting (`_extruction`) - Extra Validation Required**

If using `_extruction` for custom token accounting:
- YOU MUST verify no hash collisions with your existing strategies
- Without balance validation, the strategy can access ALL approved tokens
- Hash collision = potential fund loss through unintended token access

```solidity
// Custom accounting example - verify uniqueness!
bytes memory program = bytes.concat(
    p.build(Extruction._extruction, 
        ExtructionArgsBuilder.build(customAccountingContract, args)),
    p.build(Controls._salt, abi.encodePacked(keccak256("unique-id-v1")))
);
```

#### Why This Matters

**Problem: Strategies Depend on Each Other Through Approvals**

```
Scenario: Maker creates 3 strategies with common token approvals

Strategy A: ✓ USDC/WETH with proper _staticBalancesXD
Strategy B: ✓ DAI/WETH with proper _staticBalancesXD  
Strategy C: ✗ Loose strategy without balance instruction

Risk: Strategy C can execute with ANY tokens that have SwapVM approvals
      (USDC, DAI, WETH, etc.), bypassing intended token restrictions

Attack: Taker executes Strategy C, arbitrarily choosing tokenIn/tokenOut
        from all approved tokens, potentially draining funds
```

**Without Proper Hash Uniqueness:**

| Risk | Description | Mitigation |
|------|-------------|------------|
| **Cross-Strategy Token Access for Non-Aqua mode** | Loose strategies access all approved tokens | Always include `_staticBalancesXD` or `_dynamicBalancesXD` |
| **Hash Collision** | Identical programs share storage/state | Use `_salt` with unique values |
| **Storage Conflicts** | Multiple strategies interfere with each other | Ensure unique `orderHash` for each strategy |
| **Approval Exploitation** | Taker chooses unexpected token pairs | Encode tokens in program via balance instructions |

#### Best Practices Summary

```solidity
// ✓ COMPLETE SAFE EXAMPLE
Program memory p = ProgramBuilder.init(_opcodes());
bytes memory program = bytes.concat(
    // 1. Include balance instruction (ties tokens to strategy)
    p.build(Balances._staticBalancesXD,
        BalancesArgsBuilder.build(
            dynamic([USDC, WETH]),
            dynamic([1000e6, 0.5e18])
        )),
    
    // 2. Your swap logic
    p.build(LimitSwap._limitSwap1D, 
        LimitSwapArgsBuilder.build(USDC, WETH)),
    
    // 3. Add salt for uniqueness (if you have multiple similar strategies)
    p.build(Controls._salt, abi.encodePacked(uint256(1)))
);
```

**Key Takeaway:** The `orderHash` identifies your strategy and determines storage isolation. Always ensure it's unique and that tokens are explicitly bound to each strategy through balance instructions.

---

### Balance Management Options

#### Option 1: Static Balances (1D Single-Direction Strategies)

```solidity
// Fixed exchange rate for 1D strategies (limit orders, auctions)
p.build(Balances._staticBalancesXD, ...)
```

**Characteristics:**
- Fixed exchange rate throughout order lifetime
- Supports partial fills with amount invalidators
- No state storage (pure function)
- Single-direction trades only
- Ideal for: Limit orders, Dutch auctions, TWAP, DCA, RFQ, range orders, stop-loss

#### Option 2: AMM Strategies (2D/XD Bidirectional) - Two Storage Choices

Both options use the **same AMM logic** and support identical features. The only difference is where balances are stored:

##### 2A. Dynamic Balances (SwapVM Internal)

```solidity
// Persistent AMM-style order with isolated liquidity
p.build(Balances._dynamicBalancesXD, ...)
// Sign with EIP-712
```

**Storage:** SwapVM contract (per-maker isolation)  
**Setup:** Sign order off-chain (gasless)  
**Use Case:** Individual AMM strategies, custom curves  
**Key Point:** Replicates Aqua-like functionality but with signature-based orders (no deposits)  
**Note:** Each maker's liquidity is isolated - no pooling with others

##### 2B. Aqua Protocol (External Shared Liquidity)

```solidity
// Use Aqua's shared liquidity layer
MakerTraits makerTraits = MakerTraitsLib.build({
    useAquaInsteadOfSignature: true
});
// Requires prior: aqua.ship(token, amount)
```

**Storage:** Aqua protocol (external)  
**Setup:** Deposit to Aqua via `ship()`  
**Use Case:** Share liquidity across multiple strategies  
**Key Difference:** Unlike isolated dynamic balances, Aqua enables shared liquidity

See [Aqua Protocol](https://github.com/1inch/aqua) for details

### Maker Security

Your orders are protected by:

- **EIP-712 Signatures** - Orders cannot be modified
- **Expiration Control** - Orders expire when you want
- **Balance Limits** - Cannot trade more than specified
- **Custom Receivers** - Send tokens where you want
- **Hooks** - Custom validation logic
- **Order Invalidation** - One-time execution via bitmaps

**Best Practices:**
- Always set expiration dates
- Use `_invalidateBit1D` for one-time orders
- Validate rates match market conditions
- Consider MEV protection (`_decayXD`)
- ⚠️ **WETH Unwrapping:** Only use `shouldUnwrapWeth=true` with canonical WETH. Avoid any tokens with `withdraw()` functions - underlying assets may get stuck in SwapVM

---

## 🏃 For Takers (Swap Executors)

Takers execute swaps against maker orders to arbitrage or fulfill trades.

### Your Role

- **Find profitable orders** to execute
- **Specify swap amount** (either input or output)
- **Provide dynamic data** for adaptive instructions
- **Execute swaps** on-chain

### Executing a Swap

```solidity
// 1. Find an order to execute
ISwapVM.Order memory order = findProfitableOrder();

// 2. Preview the swap (free call)
(uint256 amountIn, uint256 amountOut) = swapVM.asView().quote(
    order,
    USDC,           // Token you're trading
    WETH,           // Token you're receiving
    1000e6,         // Amount (input if isExactIn=true)
    takerTraitsData // Your execution parameters
);

// 3. Prepare taker parameters
bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
    isExactIn: true,              // You specify input amount
    threshold: minAmountOut,      // Minimum output (slippage protection)
    to: yourAddress,              // Where to receive tokens
    shouldUnwrapWeth: false,      // Keep as WETH
    // Optional features:
    hasPreTransferInHook: false,
    isFirstTransferFromTaker: false
}));

// 4. Execute the swap
(uint256 actualIn, uint256 actualOut, bytes32 orderHash) = swapVM.swap(
    order,
    USDC,
    WETH,
    1000e6,        // Your input amount
    abi.encodePacked(signature, takerTraits, customData)
);
```

### Providing Dynamic Data

Some instructions read data from takers at execution time:

```solidity
// Pack custom data for instructions
bytes memory customData = abi.encode(
    oraclePrice,    // For oracle-based adjustments
    maxGasPrice,    // For gas-sensitive orders
    userPreference  // Any custom parameters
);

// Instructions access via:
// ctx.tryChopTakerArgs(32) - extracts 32 bytes
```

### Understanding isExactIn

The `isExactIn` flag determines which amount you control:

| isExactIn | You Specify | VM Computes | Use Case |
|-----------|------------|-------------|----------|
| true | Input amount | Output amount | "I want to sell exactly 1000 USDC" |
| false | Output amount | Input amount | "I want to buy exactly 0.5 WETH" |

### Taker Security

Your swaps are protected by:

- **Threshold Validation** - Minimum output / maximum input
- **Slippage Protection** - Via threshold amounts
- **Custom Recipients** - Send tokens anywhere
- **Pre-hooks** - Validate before execution
- **Quote Preview** - Check amounts before executing

**Best Practices:**
- Always use `quote()` before `swap()`
- Set appropriate thresholds for slippage
- Verify order hasn't expired
- Check for MEV opportunities
- Consider gas costs vs profit

### MEV Opportunities

SwapVM creates MEV opportunities:

1. **Arbitrage** - Price differences between orders
2. **Liquidations** - Execute against distressed positions
3. **JIT Liquidity** - Provide liquidity just-in-time
4. **Sandwich Protection** - Some orders use `_decayXD` for protection

---

## 🛠 For Developers

Build custom instructions and integrate SwapVM into your protocols.

### Understanding the Execution Environment

#### The Context Structure

Every instruction receives a `Context` with three components:

```
Context
├── VM (Execution State)
│   ├── nextPC ───────────────────── Program counter (MUTABLE - for jumps)
│   ├── programPtr ───────────────── Bytecode being executed
│   ├── takerArgsPtr ─────────────── Taker's dynamic data (MUTABLE - via tryChopTakerArgs)
│   └── opcodes ──────────────────── Available instructions array
│
├── SwapQuery (READ-ONLY)
│   ├── orderHash ────────────────── Unique order identifier
│   ├── maker ────────────────────── Liquidity provider address
│   ├── taker ────────────────────── Swap executor address
│   ├── tokenIn ──────────────────── Input token address
│   ├── tokenOut ─────────────────── Output token address
│   └── isExactIn ────────────────── Taker's swap direction (true = exact in, false = exact out)
│
└── SwapRegisters (MUTABLE)
    ├── balanceIn ────────────────── Maker's available input token balance
    ├── balanceOut ───────────────── Maker's available output token balance
    ├── amountIn ─────────────────── Input amount (taker provides OR VM computes)
    └── amountOut ────────────────── Output amount (taker provides OR VM computes)
```

### Order Configuration (MakerTraits & TakerTraits)

```
MakerTraits (256-bit packed)
├── Bit Flags (bits 245-255)
│   ├── shouldUnwrapWeth (255) ──── Unwrap WETH to ETH on output
│   ├── useAquaInsteadOfSignature (254) ─ Use Aqua balance instead of signature
│   ├── allowZeroAmountIn (253) ── Allow zero amountIn (skip validation)
│   ├── hasPreTransferInHook (252) ── Call maker before input transfer
│   ├── hasPostTransferInHook (251) ── Call maker after input transfer
│   ├── hasPreTransferOutHook (250) ── Call maker before output transfer
│   ├── hasPostTransferOutHook (249) ── Call maker after output transfer
│   ├── preTransferInHookHasTarget (248) ── Hook has custom target
│   ├── postTransferInHookHasTarget (247)
│   ├── preTransferOutHookHasTarget (246)
│   └── postTransferOutHookHasTarget (245)
│
├── Data Slices Indexes (bits 160-223, 64 bits)
│   └── Packed 4x uint16 offsets for hook data slices
│
└── Receiver (bits 0-159, 160 bits)
    └── Custom recipient address (0 = maker)
```

```
TakerTraits (Variable-length with 176-bit header)
├── Header (22 bytes packed)
│   ├── Slices Indexes (160 bits) ── 10x uint16 offsets for data slices
│   └── Bit Flags (16 bits)
│       ├── isExactIn (0) ────────── true = specify input, false = output
│       ├── shouldUnwrapWeth (1) ── Unwrap WETH to ETH on output
│       ├── hasPreTransferInCallback (2) ── Call taker before input transfer
│       ├── hasPreTransferOutCallback (3) ── Call taker before output transfer
│       ├── isStrictThresholdAmount (4) ── true = exact, false = min/max
│       ├── isFirstTransferFromTaker (5) ── Who transfers first
│       └── useTransferFromAndAquaPush (6) ── SwapVM does transferFrom + Aqua push
│
└── Variable-length Data Slices
    ├── threshold (0 or 32 bytes) ── Min output or max input
    ├── to (0 or 20 bytes) ───────── Custom recipient
    ├── deadline (0 or 5 bytes) ──── Unix timestamp (uint40)
    ├── preTransferInHookData ────── Data for maker pre-in hook
    ├── postTransferInHookData ───── Data for maker post-in hook
    ├── preTransferOutHookData ──── Data for maker pre-out hook
    ├── postTransferOutHookData ─── Data for maker post-out hook
    ├── preTransferInCallbackData ─ Data for taker pre-in callback
    ├── preTransferOutCallbackData ─ Data for taker pre-out callback
    ├── instructionsArgs ──────────── Data consumed by VM instructions
    └── signature ─────────────────── EIP-712 signature for order
```

### Instruction Capabilities

Instructions **compute swap amounts only** - they do NOT execute the actual token transfers (except protocol fee instructions which can transfer fees). The swap itself happens after all instructions complete.

Instructions can **only** modify three aspects of the Context:

#### 1. Swap Registers (`ctx.swap.*`)
All four registers can be modified to calculate swap amounts:
- `balanceIn` / `balanceOut` - Set or adjust available balances for calculations
- `amountIn` / `amountOut` - Compute the missing swap amount

#### 2. Program Counter (`ctx.vm.nextPC`)
Control execution flow between instructions:
- Skip instructions (jump forward)
- Loop back to previous instructions
- Conditional branching based on computation state

#### 3. Taker Data (`ctx.tryChopTakerArgs()`)
Consume data provided by taker at execution time:
- Read dynamic parameters for calculations
- Process variable-length data
- Advance the taker data pointer

#### Special: Nested Execution (`ctx.runLoop()`)
Instructions can invoke `ctx.runLoop()` to execute remaining instructions and then continue:
- Apply pre-processing, let other instructions compute amounts, then post-processing
- Wrap amount computations with fee calculations
- Wait for amount computation before validation
- Implement complex multi-phase amount calculations

### Instruction Security Model

Instructions operate within SwapVM's execution framework:

**What Instructions CAN Do:**
- ✅ Read all context data (query, VM state, registers)
- ✅ Modify the 4 swap registers
- ✅ Change program counter for control flow
- ✅ Consume taker-provided data
- ✅ Read and write to their own storage mappings
- ✅ Make external calls (via `_extruction`)
- ✅ Execute fee transfers (protocol fee instructions)

**What Instructions CANNOT Do:**
- ❌ Modify query data (maker, taker, tokens, etc. - immutable)
- ❌ Transfer swap tokens directly (except protocol fees)
- ❌ Bypass SwapVM's validation (thresholds, signatures, etc.)
- ❌ Modify core SwapVM protocol state
- ❌ Execute after swap is complete

**Security Considerations:**
- Reentrancy protection only for Aqua settlement (via transient storage when taker pushes)
- Gas limited by block and transaction
- External calls risk managed by maker's instruction choice
- Deterministic execution

### Building a Custom Router

Routers define available instructions:

```solidity
contract MyRouter is SwapVM, Opcodes {
    constructor(address aqua) 
        SwapVM(aqua, "MyRouter", "1.0") 
        Opcodes(aqua) 
    {}
    
    function _instructions() internal pure override 
        returns (function(Context memory, bytes calldata) internal[] memory) 
    {
        // Return your instruction set
        return _opcodes();
    }
}
```

### Testing Instructions

Use the provided `CoreInvariants` base contract to ensure your instructions maintain all invariants:

```solidity
contract MyInstructionTest is Test, OpcodesDebug, CoreInvariants {
    function test_MyInstruction() public {
        // Build program with your instruction
        bytes memory program = buildProgramWithMyInstruction();
        ISwapVM.Order memory order = createOrder(program);
        
        // Validate all core invariants are maintained
        assertAllInvariants(swapVM, order, tokenA, tokenB);
    }
}
```

For manual testing:

```solidity
function testMyInstructionManually() public {
    // Create test context
    Context memory ctx = Context({
        vm: VM({
            isStaticContext: false,
            nextPC: 0,
            programPtr: CalldataPtrLib.from(program),
            takerArgsPtr: CalldataPtrLib.from(takerData),
            opcodes: _opcodes()
        }),
        query: SwapQuery({
            orderHash: bytes32(0),
            maker: makeAddr("maker"),
            taker: makeAddr("taker"),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            isExactIn: true
        }),
        swap: SwapRegisters({
            balanceIn: 1000e18,
            balanceOut: 2000e18,
            amountIn: 100e18,
            amountOut: 0
        })
    });
    
    // Execute instruction
    bytes memory args = abi.encode(0.003e9); // 0.3% fee
    MyInstruction._myInstruction(ctx, args);
    
    // Verify results
    assertGt(ctx.swap.amountOut, 0);
}
```

---

## 🔒 Security Model

### Core Invariants as Security Foundation

SwapVM's security is built on maintaining fundamental invariants that ensure economic correctness:

1. **Exact In/Out Symmetry** - Prevents internal arbitrage opportunities
2. **Swap Additivity** - Ensures no gaming through order splitting
3. **Quote/Swap Consistency** - Guarantees predictable execution
4. **Price Monotonicity** - Natural market dynamics are preserved
5. **Rounding Favors Maker** - Protects liquidity providers from value extraction
6. **Balance Sufficiency** - Prevents impossible trades

These invariants are enforced at the VM level and validated through comprehensive test suites.

### Protocol-Level Security

**Core Security Features:**
- **EIP-712 Typed Signatures** - Prevents signature malleability
- **Order Hash Uniqueness** - Each order has unique identifier
- **Reentrancy Protection** - Transient storage locks (EIP-1153)
- **Overflow Protection** - Solidity 0.8+ automatic checks
- **Gas Limits** - Block gas limit prevents infinite loops
- **Invariant Validation** - All instructions must maintain core invariants

**Signature Verification:**
```solidity
// Standard EIP-712
orderHash = keccak256(abi.encode(
    ORDER_TYPEHASH,
    order.maker,
    order.traits,
    keccak256(order.program)
));

// Or Aqua Protocol (no signature needed)
if (useAquaInsteadOfSignature) {
    require(AQUA.balances(maker, orderHash, token) >= amount);
}
```

### Maker Security

**Protection Mechanisms:**

| Feature | Description | Implementation |
|---------|-------------|----------------|
| **Signature Control** | Orders cannot be modified | EIP-712 signatures |
| **Expiration** | Time-limited orders | `_deadline` instruction or TakerTraits deadline |
| **Balance Limits** | Cannot exceed specified amounts | Register bounds checking |
| **One-time Execution** | Prevent replay | `_invalidateBit1D` instruction |
| **Custom Logic** | Hooks for validation | Pre/post transfer hooks |
| **Receiver Control** | Specify token recipient | `receiver` in MakerTraits |

> **⚠️ HOOK EXECUTION ORDER WARNING FOR MAKERS**
>
> **Taker Controls Transfer Order:** The taker specifies `isFirstTransferFromTaker` flag, which determines whether the taker transfers input tokens first or receives output tokens first. This means the actual execution order of your hooks depends on the taker's choice.
>
> **Complete Execution Sequence:**
> - `isFirstTransferFromTaker = true`:
>   1. `preTransferInHook` (maker)
>   2. `preTransferInCallback` (taker)
>   3. **Input token settlement** (details below)
>   4. `postTransferInHook` (maker)
>   5. `preTransferOutHook` (maker)
>   6. `preTransferOutCallback` (taker)
>   7. **Output token settlement** (details below)
>   8. `postTransferOutHook` (maker)
>
> - `isFirstTransferFromTaker = false`:
>   1. `preTransferOutHook` (maker)
>   2. `preTransferOutCallback` (taker)
>   3. **Output token settlement** (details below)
>   4. `postTransferOutHook` (maker)
>   5. `preTransferInHook` (maker)
>   6. `preTransferInCallback` (taker)
>   7. **Input token settlement** (details below)
>   8. `postTransferInHook` (maker)
>
> **Settlement Mechanisms:**
> - **Input (non-Aqua):** `IERC20.transferFrom(taker → receiver)`
> - **Input (Aqua + useTransferFromAndAquaPush):** `IERC20.transferFrom(taker → SwapVM) + AQUA.push()`
> - **Input (Aqua without useTransferFromAndAquaPush):** Balance validation only (taker must push tokens before `swap()`)
> - **Output (non-Aqua):** `IERC20.transferFrom(maker → to)`
> - **Output (Aqua):** `AQUA.pull(maker → to)`
>
> **Maker Responsibility:** When implementing hooks, you must account for both possible execution orders. Do not assume a fixed sequence (e.g., assuming `preTransferInHook` always executes before `preTransferOutHook`). Note that taker callbacks are executed between your hooks - this is controlled by the taker and outside your control.
>
> **Best Practices:**
> - Design hooks to be order-independent (stateless validation)
> - If order matters, explicitly check transfer direction within your hook logic
> - Test your hooks with both `isFirstTransferFromTaker` values
> - Be aware that taker callbacks execute between your hooks

**Risk Mitigations:**
```solidity
// Limit order exposure
p.build(Invalidators._invalidateBit1D, bitIndex);

// Add expiration via _deadline instruction in program
p.build(Controls._deadline, ControlsArgsBuilder.buildDeadline(block.timestamp + 1 hours));

// Or via TakerTraits deadline field

// MEV protection
p.build(Decay._decayXD, DecayArgsBuilder.build(30));
```

### Taker Security

**Protection Mechanisms:**

| Feature | Description | Implementation |
|---------|-------------|----------------|
| **Slippage Protection** | Min output/max input | `threshold` in TakerTraits |
| **Amount Validation** | Exact amounts enforced | `isStrictThresholdAmount` flag |
| **Preview Execution** | Check before swap | `quote()` function |
| **Custom Recipients** | Control token destination | `to` in TakerTraits |
| **Hook Validation** | Pre-execution checks | `hasPreTransferInHook` |

**Risk Mitigations:**
```solidity
// Set minimum output
takerTraits.threshold = minAcceptableOutput;

// Preview first
(amountIn, amountOut) = swapVM.asView().quote(...);
require(amountOut >= minRequired, "Insufficient output");

// Then execute
swapVM.swap(...);
```

### Instruction Security

**Sandboxed Execution:**

```
┌─────────────────────────────────────────┐
│         Instruction Sandbox             │
├─────────────────────────────────────────┤
│  ✅ Allowed:                            │
│  • Read context data                    │
│  • Modify swap registers                │
│  • Control flow (jumps)                 │
│  • Pure computations                    │
├─────────────────────────────────────────┤
│  ❌ Restricted:                         │
│  • External calls                       │
│  • Storage modification                 │
│  • Query data modification              │
│  • Infinite loops                       │
└─────────────────────────────────────────┘
```

**Validation Example:**
```solidity
function _safeInstruction(Context memory ctx, bytes calldata args) internal {
    // ✅ Can read and modify swap registers
    ctx.swap.amountIn = ctx.swap.amountIn * 99 / 100;
    
    // ✅ Can read query data (read-only)
    address maker = ctx.query.maker;
    
    // ✅ Can modify VM state for control flow
    ctx.vm.nextPC = newPC;
    
    // ✅ Can consume taker data
    bytes calldata data = ctx.tryChopTakerArgs(32);
    
    // ❌ Cannot do:
    // IERC20(token).transfer(...);  // No external calls
    // ctx.query.maker = newMaker;    // Query is read-only
    // selfdestruct();                // No destructive operations
}
```

### Risk Assessment and Mitigation Options

#### Program Construction Risks (Maker Responsibility)

Makers define programs that trade assets on their behalf and are responsible for correctness:

**Logic Errors**
- **Risk:** Incorrect instruction sequence or arguments
- **Mitigation:** Test thoroughly, use proven patterns, audit critical strategies

**Replay Attacks**
- **Risk:** Order executed multiple times or overfilled
- **Mitigation:** 
  - Include `_invalidateBit1D` for one-time execution
  - Use `_invalidateTokenIn/Out1D` for partial fills
  - Set appropriate expiration

**Price Exposure**
- **Risk:** Trades at unfavorable market conditions
- **Mitigation:**
  - Add `_requireMinRate1D` checks
  - Set expiration timestamps
  - Use oracle price bounds

**Order Uniqueness**
- **Risk:** Cannot create multiple identical orders
- **Mitigation:** Use `_salt` instruction to differentiate, vary parameters slightly

#### Execution Risks (Taker Responsibility)

Takers control execution parameters and must verify rates:

**Rate Slippage**
- **Risk:** Receive worse exchange rate than expected
- **Mitigation Options:**
  - **Threshold Protection:**
    - Exact: `isStrictThresholdAmount = true`
    - Min output: `isExactIn = true, threshold = minOut`
    - Max input: `isExactIn = false, threshold = maxIn`
  - **Callback Validation:**
    - Pre-transfer hook: `hasPreTransferInHook = true`
    - Custom logic via `ITakerCallbacks`
  - **Return Data Verification:**
    - Check returned `(amountIn, amountOut)`
    - Compare with `quote()` results

**MEV Attacks**
- **Risk:** Front-running or sandwich attacks
- **Mitigation:** Use private mempools (Flashbots), set tight thresholds, use commit-reveal patterns

**Failed Transactions**
- **Risk:** Wasted gas from reverts
- **Mitigation:** Always call `quote()` first, verify token balances, check order expiration

#### SwapVM Security Guarantees

The protocol provides these built-in protections:

**Parameter Integrity**
- Never violates maker/taker constraints through strict trait enforcement

**Balance Isolation**
- Each maker's liquidity is separate using per-maker storage slots

**Instruction Sandboxing**
- No external calls from instructions (pure/view functions only)

**Reentrancy Protection**
- Prevents recursive calls using transient locks (EIP-1153)

**Overflow Protection**
- Safe arithmetic operations with Solidity 0.8+ checks

**Deterministic Execution**
- Same inputs always produce same outputs (no external dependencies in core logic)

---

## 🔬 Advanced Topics

### AMM Instruction Ordering (Canonical)

The order in which instructions appear in an AMM program is critical for correct accounting — specifically for protocol fee isolation, liquidity growth, and conservation laws. The canonical orderings below are validated by `AquaAccounting.t.sol` and `SwapVmAccounting.t.sol`.

#### Aqua Protocol (balance managed by Aqua)

```
aquaProtocolFeeAmountIn → [decay?] → [concentrate?] → flatFee → swap / peggedSwap → salt
```

```solidity
// XYC AMM with protocol fee + flat fee + MEV protection
bytes memory program = bytes.concat(
    p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeReceiver)),
    p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),                          // optional
    p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, concentrateArgs),               // optional
    p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeBps)),
    p.build(XYCSwap._xycSwapXD),
    p.build(Controls._salt, saltArgs)
);

// Pegged swap variant (replaces concentrate + xycSwap)
bytes memory program = bytes.concat(
    p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeReceiver)),
    p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),                          // optional
    p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeBps)),
    p.build(PeggedSwap._peggedSwapGrowPriceRange2D, peggedArgs),
    p.build(Controls._salt, saltArgs)
);
```

#### Dynamic Balances (SwapVM internal, no Aqua)

```
protocolFeeAmountIn → dynamicBalances → [decay?] → [concentrate?] → flatFee → swap / peggedSwap → salt
```

```solidity
// XYC AMM with protocol fee + flat fee + MEV protection
bytes memory program = bytes.concat(
    p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeReceiver)),
    p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(tokens, initialBalances)),
    p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),                          // optional
    p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, concentrateArgs),               // optional
    p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeBps)),
    p.build(XYCSwap._xycSwapXD),
    p.build(Controls._salt, saltArgs)
);

// Pegged swap variant
bytes memory program = bytes.concat(
    p.build(Fee._protocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeReceiver)),
    p.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(tokens, initialBalances)),
    p.build(Decay._decayXD, DecayArgsBuilder.build(decayPeriod)),                          // optional
    p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeBps)),
    p.build(PeggedSwap._peggedSwapGrowPriceRange2D, peggedArgs),
    p.build(Controls._salt, saltArgs)
);
```

#### Why This Order Matters

| Position | Instruction | Reason |
|----------|-------------|--------|
| 1st | **Protocol Fee** | Extracted from `amountIn` **before** balances are touched — ensures fee is isolated from pool reserves and does not inflate liquidity |
| 2nd | **Dynamic Balances** (non-Aqua only) | Loads/initializes maker's isolated reserves; wraps all subsequent instructions via `runLoop()` |
| 3rd | **Decay** | Applies virtual reserve adjustment based on time since last trade — must see real balances |
| 4th | **Concentrate** | Shifts reserves into concentrated range — must happen before the swap but after decay |
| 5th | **Flat Fee** | Reduces effective `amountIn` before swap calculation — fee amount stays in the pool, growing liquidity |
| 6th | **Swap / PeggedSwap** | Core AMM calculation using final adjusted registers |
| Last | **Salt** | Order uniqueness — pure hash modifier, no effect on computation |

**Key invariant:** `pool_balance + protocol_fee = initial_balance + total_amountIn` (Token A conservation). Placing protocol fee first guarantees it is cleanly separated from pool accounting. Placing flat fee after concentrate ensures the retained fee grows liquidity correctly.

See `test/AquaAccounting.t.sol` and `test/SwapVmAccounting.t.sol` for comprehensive conservation law tests.

---

### Concentrated Liquidity

Provide liquidity within specific price ranges:

```solidity
// Calculate concentration parameters
(uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
    1000e6,   // balanceA
    0.5e18,   // balanceB
    2000e18,  // current price
    1900e18,  // lower bound
    2100e18   // upper bound
);

// Build CLMM strategy
bytes memory program = bytes.concat(
    p.build(Balances._dynamicBalancesXD, balances),
    p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, 
        XYCConcentrateArgsBuilder.build2D(tokenA, tokenB, deltaA, deltaB)),
    p.build(Fee._flatFeeAmountInXD, fee),
    p.build(XYCSwap._xycSwapXD)
);
```

### 1inch Fusion Orders

Complex multi-instruction strategies:

```solidity
// Dutch auction + gas adjustment + oracle + rate limit
bytes memory program = bytes.concat(
    p.build(Balances._staticBalancesXD, ...),
    p.build(DutchAuction._dutchAuctionBalanceOut1D, ...),
    p.build(BaseFeeAdjuster._baseFeeAdjuster1D, ...),
    p.build(OraclePriceAdjuster._oraclePriceAdjuster1D, ...),
    p.build(MinRate._adjustMinRate1D, ...),
    p.build(LimitSwap._limitSwap1D, ...)
);
```

### Protocol Fee Instructions

SwapVM offers two protocol fee instructions with different settlement mechanisms:

**1. `_protocolFeeAmountOutXD` - Direct ERC20 Transfer**
- Uses standard `transferFrom` to collect fees
- Requires maker to have approved SwapVM contract
- Fee is transferred directly from maker to recipient
- Suitable for standard ERC20 tokens

**2. `_aquaProtocolFeeAmountOutXD` - Aqua Protocol Integration**
- Uses Aqua's `pull` function for fee collection
- Works with orders using Aqua balance management
- No separate approval needed (uses Aqua's existing permissions)
- Enables batched fee collection and gas optimization

**Usage Example:**
```solidity
// Direct ERC20 protocol fee
p.build(Fee._protocolFeeAmountOutXD, 
    FeeArgsBuilder.buildProtocolFee(10, treasury)); // 0.1% to treasury

// Aqua protocol fee (for Aqua-managed orders)
p.build(Fee._aquaProtocolFeeAmountOutXD,
    FeeArgsBuilder.buildProtocolFee(10, treasury)); // 0.1% via Aqua
```

Both calculate fees identically but differ in the transfer mechanism.

### MEV Protection Strategies

```solidity
// Virtual balance decay
p.build(Decay._decayXD, DecayArgsBuilder.build(30)); // 30s decay

// Progressive fees (larger swaps pay more)
p.build(Fee._progressiveFeeInXD, ...);  // or _progressiveFeeOutXD

/* Progressive Fee Improvements:
 * New formula: dx_eff = dx / (1 + λ * dx / x) 
 * - Maintains near-perfect exact in/out symmetry
 * - Only ~1 gwei asymmetry from safety ceiling operations
 * - Mathematically reversible for consistent pricing
 */

// Time-based pricing
p.build(DutchAuction._dutchAuctionBalanceOut1D, ...);
```

### TWAP (Time-Weighted Average Price) Configuration

The `_twap` instruction implements a sophisticated selling strategy with:
- **Linear liquidity unlocking** over time
- **Exponential price decay** (Dutch auction) for price discovery
- **Automatic price bumps** after illiquidity periods
- **Minimum trade size enforcement**

#### Minimum Trade Size Guidelines

Set `minTradeAmountOut` 1000x+ larger than expected gas costs:

| Network | Gas Cost | Recommended Min Trade |
|---------|----------|----------------------|
| Ethereum | $50 | $50,000+ |
| Arbitrum/Optimism | $0.50 | $500+ |
| BSC/Polygon | $0.05 | $50+ |

This ensures gas costs remain <0.1% of trade value.

#### Price Bump Configuration

The `priceBumpAfterIlliquidity` compensates for mandatory waiting periods:

| Min Trade % of Balance | Unlock Time | Recommended Bump |
|----------------------|-------------|------------------|
| 0.1% | 14.4 min | 5-10% (1.05e18 - 1.10e18) |
| 1% | 14.4 min | 10-20% (1.10e18 - 1.20e18) |
| 5% | 1.2 hours | 30-50% (1.30e18 - 1.50e18) |
| 10% | 2.4 hours | 50-100% (1.50e18 - 2.00e18) |

Additional factors:
- **Network gas costs**: Higher gas → larger bumps
- **Pair volatility**: Volatile pairs → larger bumps
- **Market depth**: Thin markets → higher bumps

### Debug Instructions

SwapVM reserves opcodes 1-10 for debugging utilities, available only in debug routers:

**Available Debug Instructions:**
- `_printSwapRegisters` - Logs all 4 swap registers (balances and amounts)
- `_printSwapQuery` - Logs query data (orderHash, maker, taker, tokens, isExactIn)
- `_printContext` - Logs complete execution context
- `_printFreeMemoryPointer` - Logs current memory usage
- `_printGasLeft` - Logs remaining gas

**Usage:**
```solidity
// Deploy debug router
SwapVMRouterDebug debugRouter = new SwapVMRouterDebug(aquaAddress);

// Include debug instructions in program
bytes memory program = bytes.concat(
    p.build(Balances._staticBalancesXD, ...),
    p.build(Debug._printSwapRegisters),  // Debug output
    p.build(LimitSwap._limitSwap1D, ...),
    p.build(Debug._printContext)          // Final state
);
```

**Note:** Debug instructions are no-ops in production routers and should only be used for development and testing.

### Program Size Limitations

SwapVM programs have an effective size limit of **65,535 bytes** (64KB) due to control flow instruction addressing.

**Technical Details:**
- The VM itself (`ContextLib.runLoop`) uses `uint256` for the program counter and can execute programs of any size
- Control flow instructions (`_jump`, `_jumpIfTokenIn`, `_jumpIfTokenOut`) use `uint16` (2-byte) encoding for jump targets
- Jump targets are limited to positions 0-65,535 within the bytecode
- Programs larger than 65KB can execute, but jump instructions cannot address positions >= 65,536

**Practical Impact:**
- This limitation is **not restrictive** in practice
- Typical strategies are 100-1,000 bytes
- Even complex multi-instruction programs rarely exceed 5KB
- 65KB ≈ 1,000-30,000 instructions (depending on argument sizes)

**Workarounds for Large Programs:**
If you need custom control flow beyond byte 65,535:
```solidity
// Use Extruction with arbitrary uint256 nextPC
p.build(Extruction._extruction, 
    ExtructionArgsBuilder.build(customControlContract, args))
```

The `Extruction` instruction can set arbitrary `uint256` program counter values, enabling custom control flow logic for edge cases requiring programs larger than 64KB.

**Example Program Sizes:**
| Strategy Type | Typical Size |
|--------------|-------------|
| Simple limit order | ~50 bytes |
| Dutch auction + fees | ~100 bytes |
| AMM with MEV protection | ~200 bytes |
| Complex multi-conditional | ~500 bytes |
| Maximum practical | ~5,000 bytes |

### Gas Optimization

**Architecture Benefits:**
- Transient storage (EIP-1153) for reentrancy guards
- Zero deployment cost for makers
- Compact bytecode encoding (8-bit opcodes)

**Tips for Makers:**
- Use `_staticBalancesXD` for single-direction trades with fixed rates
- Use `_dynamicBalancesXD` for AMM strategies with automatic rebalancing
- Pack multiple operations in single program
- Minimize argument sizes

**Tips for Takers:**
- Batch multiple swaps
- Use `quote()` to avoid failed transactions
- Consider gas costs in profit calculations

---

## 🚀 Getting Started

### Installation

```bash
npm install @1inch/swap-vm
# or
yarn add @1inch/swap-vm
```

### Quick Example

```solidity
import { SwapVMRouter } from "@1inch/swap-vm/contracts/SwapVMRouter.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";

// Deploy router
SwapVMRouter router = new SwapVMRouter(aquaAddress, "MyDEX", "1.0");

// Create and execute orders...
```

### Resources

- **GitHub**: [github.com/1inch/swap-vm](https://github.com/1inch/swap-vm)
- **Documentation**: See `/docs` directory
- **Tests**: Comprehensive examples in `/test`
- **Audits**: Security review reports in `/audits`

---

## Known Limitations

### Token Support Limitations

**Fee-on-Transfer Tokens:**
SwapVM does not support fee-on-transfer tokens (tokens that deduct fees during transfers). Using such tokens will cause accounting mismatches between expected and actual transferred amounts.

**ERC1155 Tokens:**
SwapVM does not support ERC1155 multi-token standard. Only ERC20 tokens are supported in the current version.

### allowZeroAmountIn with AMM Strategies

**Not Recommended:** Using `allowZeroAmountIn=true` with AMM strategies (PeggedSwap, XYCSwap, XYCConcentrate) is not recommended. This flag is intended for:
- Cross-chain bridge integration
- Limit orders with specific use cases

For AMM pools, `allowZeroAmountIn=true` can enable theoretical (but economically infeasible) dust extraction.

### Control Instruction Limitations

**_onlyTakerTokenBalanceGte / _onlyTakerTokenBalanceNonZero:**
These instructions verify the taker owns a minimum token balance. **Limitations:**
- **Not compatible with routers/aggregators** - these contracts don't hold user tokens
- **Easily bypassed via flash loans** - if the token supports flash lending, attackers can temporarily borrow the required balance

**_onlyTakerTokenSupplyShareGte:**
This instruction verifies the taker owns a minimum percentage of total token supply. **Limitations:**
- **Bypassed with ERC4626 vault tokens** - attackers can wrap/unwrap to manipulate their share
- **Bypassed with flash-mintable tokens** (e.g., DAI) - attackers can temporarily mint tokens to meet the threshold

**Use Case:** These instructions provide basic access control for specific scenarios but should not be relied upon as strong security mechanisms. Consider them convenience features rather than robust protections.

### PeggedSwap Known Limitations

#### Dust Amount Behavior (<100 wei)

For extremely small trades (≤100 wei), integer rounding can cause unexpected behavior across all swap instructions:

##### Observed Effects

**1. Monotonicity Violations**
Larger trades may receive better rates due to relative rounding error:
- **20 wei trade:** 0.3% fee = 0.06 wei → rounds UP to 1 wei (16x overcharge)
- **50 wei trade:** 0.3% fee = 0.15 wei → rounds UP to 1 wei (6x overcharge)
- **100 wei trade:** 0.3% fee = 0.30 wei → rounds UP to 1 wei (3x overcharge)

As amount increases, relative rounding error decreases, creating non-monotonic pricing.

**2. Zero Outputs**
Some dust amounts may round down to 0 output, causing transaction reverts.

**3. Quantization Steps**
Discrete jumps in exchange rates due to integer quantization.

##### Why This Happens

SwapVM uses **"rounding favors maker"** for security:
- **Fees round UP** (`Math.ceilDiv`) - maker receives full protection
- **Outputs round DOWN** (floor division) - maker keeps extra dust
- Necessary to prevent value extraction via rounding attacks

For dust amounts, rounding error dominates actual swap calculations.

##### Economic Impact: ZERO ✅

**Gas Cost Dominance:**
```
Transaction cost: ~$15 (@ 100k gas, 50 gwei, ETH=$3000)
Profit from rate improvement: ~$0.0000000000000001
Loss ratio: 500 trillion to 1
```

**Why This is Safe:**
- ❌ **NOT economically exploitable** - gas >> profit by 12+ orders of magnitude
- ✅ **Self-limiting** - only affects negligible amounts (<$0.000001)
- ✅ **Maker protected** - rounding favors liquidity providers
- ✅ **No pool drain** - would need billions of transactions

##### Testing Approach

SwapVM test suite handles dust amounts with appropriate tolerances:

```solidity
// DustAmounts.t.sol - tests 1-100 wei
monotonicityToleranceBps = 10000;  // 100% tolerance
roundingToleranceBps = 1000;        // 10% tolerance

// MicroAmounts.t.sol - tests 20 wei - 1B wei  
monotonicityToleranceBps = 1;       // 1 bps tolerance
roundingToleranceBps = 100;         // 1% tolerance
```

**Key Insight:** Invariant violations for dust amounts are **mathematical artifacts** without real-world impact. The test suite validates that all invariants hold for economically relevant trade sizes.

#### PeggedSwap Quantization in Large Pools

For pools ≥1e+27 tokens, integer quantization can create scenarios where:
- Exact-out swaps of 1 wei may require 0 wei input (due to rounding)
- This only occurs with `allowZeroAmountIn=true`

**Impact:**
- Theoretical: ~1-10 wei extractable from pools >1e+27 tokens
- Economic: Completely infeasible (gas costs exceed profit)

**Recommendations:**
- ❌ DO NOT use `allowZeroAmountIn=true` with PeggedSwap AMM pools
- ✅ DO use `allowZeroAmountIn=true` for limit orders (intended use case)

---

## 📄 License

This project is licensed under the **LicenseRef-Degensoft-SwapVM-1.1**

See the [LICENSE](LICENSE) file for details.
See the [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) file for information about third-party software, libraries, and dependencies used in this project.

**Contact for licensing inquiries:**
- 📧 license@degensoft.com 
- 📧 legal@degensoft.com
