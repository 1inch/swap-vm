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

For a catalog of strategy types and composition examples, see `docs/PROGRAMS.md`.

---

## 📚 Table of Contents

- [Overview](#overview)
- [Deployment](#deployment)
- [How It Works](#how-it-works)
- [Core Invariants](#core-invariants)
- [For Makers (Liquidity Providers)](#for-makers-liquidity-providers)
- [For Takers (Swap Executors)](#for-takers-swap-executors)
- [For Developers](#for-developers)
- [Security Model](#security-model)
- [Getting Started](#getting-started)
- [License](#license)

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

### Swap Registers

SwapVM uses `SwapRegisters` (5 fields) to compute token swaps and track execution accounting:

```
┌────────────────────────────────────────────────────────────┐
│                    SwapRegisters                           │
├────────────────────────────────────────────────────────────┤
│  balanceIn:  Maker's available input token balance         │
│  balanceOut: Maker's available output token balance        │
│  amountIn:   Input amount (taker provides OR VM computes)  │
│  amountOut:  Output amount (taker provides OR VM computes) │
│  amountNetPulled: Net amount pulled (fees accounting)│
└────────────────────────────────────────────────────────────┘
```

**The Core Principle:**
1. **Taker specifies ONE amount** (either `amountIn` or `amountOut`)
2. **VM computes the OTHER amount** using `SwapRegisters`
3. **Instructions modify registers** to apply fees, adjust rates, etc.

### Execution Flow

> **VERY IMPORTANT:** Instruction order is security-critical. The same instructions in a different order can change strategy behavior and, in some cases, introduce dangerous outcomes. Any SwapVM program used by makers and takers should be audited before production use.


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
  ↑   ↑                  ↑  ↑
  │   │                  │  └─ length (0x01)
  │   └─ length (0x4A)
  └─ opcode(0x17): staticBalances 
                         └─ opcode(0x26): limitSwap 
```

### Balance Types Explained

SwapVM offers two primary balance management approaches:

#### Static Balances (Single-Direction Trading)
Static balances are provided as fixed inputs for the swap computation and are not updated or persisted as mutable order state during execution.

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

Dynamic balances can be updated by execution and persisted as order state, so future swaps use the new balance values.

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

For AMM programs composed from swap instructions plus fee instructions, split behavior can vary:
- **Subadditive:** `swap(A) + swap(B) < swap(A+B)` (splitting is worse than one large swap)
- **Superadditive:** `swap(A) + swap(B) > swap(A+B)` (splitting is better than one large swap)
- **Strictly additive (ideal):** `swap(A) + swap(B) = swap(A+B)`

In practice, SwapVM programs are generally designed to prefer **subadditive** behavior (so order splitting does not create an advantage), while the theoretical ideal is **strict additivity**.




### 3. Quote/Swap Consistency

Quote and swap functions must return identical amounts:
- `quote()` is a view function that previews swap results
- `swap()` execution must match the quoted amounts exactly
- Essential for MEV protection and predictable execution

### 4. Price Monotonicity

Larger trades receive equal or worse prices:
- Price defined as `amountOut/amountIn` 
- Must decrease (or stay constant) as trade size increases
- Natural consequence of liquidity curves and market impact

### 5. Rounding Favors Maker

All rounding operations must favor Maker:

- Small trades (few wei) shouldn't exceed theoretical spot price
- `amountIn` always rounds UP (ceil)
- `amountOut` always rounds DOWN (floor)
- Protects makers from rounding-based value extraction

### 6. Balance Sufficiency

Trades cannot exceed available liquidity:
- Must revert if computed `amountOut > balanceOut`
- Prevents impossible trades and protects order integrity
- Enforced at the VM level before token transfers

### 7. Strategy Liveness

AMM strategies should remain live even when one reserve is temporarily depleted:
- If one asset balance reaches zero (for example, in concentrated-liquidity configurations), swaps in that direction may stop
- Reverse-direction swaps should still be possible
- Reverse flow should be able to restore depleted reserves and return the strategy to a working state


These invariants are validated through comprehensive test suites and must be maintained by any new instruction implementations.


### Testing Invariants in Your Code

SwapVM provides a reusable `CoreInvariants` base contract for testing:

```solidity
import { CoreInvariants } from "test/invariants/CoreInvariants.t.sol";

contract MyInstructionTest is Test, OpcodesDebug, CoreInvariants {
    function test_MyInstruction_MaintainsInvariants() public {
        // Create order with your instruction
        ISwapVM.Order memory order = createOrderWithMyInstruction();

        // Configure taker data used by exactIn/exactOut invariant checks
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = signAndPackTakerData(order, false, type(uint256).max);
        
        // Test all invariants at once
        assertAllInvariantsWithConfig(swapVM, order, tokenIn, tokenOut, config);
        
        // Or test specific invariants
        assertSymmetryInvariant(swapVM, order, tokenIn, tokenOut, 
            amount, tolerance, exactInData, exactOutData);
        assertMonotonicityInvariant(swapVM, order, tokenIn, tokenOut, 
            amounts, takerData, 0); // strict monotonicity
    }
}
```

Configuration options for complex scenarios:

```solidity
InvariantConfig memory config = createInvariantConfig(testAmounts, tolerance);
config.skipAdditivity = true;    // For stateless orders
config.skipMonotonicity = true;  // For fixed-rate orders
config.exactInTakerData = _signAndPackTakerData(order, true, 0);
config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
assertAllInvariantsWithConfig(swapVM, order, tokenIn, tokenOut, config);
```

See `test/invariants/ExampleInvariantUsage.t.sol` for complete examples.

---

## For Makers (Liquidity Providers)

Makers provide liquidity by creating orders/strategies with custom swap logic. This includes:

- **Defining swap logic** via a SwapVM program
- **Configuring order/strategy parameters** (type, expiration, fees, hooks)
- **Signing orders** off-chain (gasless)

### Example: creating a simple limit order

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
    p.build(Invalidators._invalidateTokenOut1D)
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

### Example: building an AMM strategy

Create a persistent, isolated AMM-style strategy:

```solidity
// Constant product AMM with 0.3% fee
Program memory p = ProgramBuilder.init(_opcodes());
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

Both options use the **same AMM logic** and support identical strategy composition. The key difference is where balances are stored and how authorization is handled.

##### 2A. Dynamic Balances (SwapVM Internal)

```solidity
// Persistent AMM-style order with isolated liquidity
p.build(Balances._dynamicBalancesXD, ...)
// Sign with EIP-712
```

**Storage:** SwapVM contract (per-maker isolation)  
**Setup:** Sign order off-chain (gasless)  
**Use Case:** Individual AMM strategies, custom curves  
**Key Point:** Signature-based AMM orders without liquidity deposits into Aqua  
**Note:** Each maker's liquidity is isolated - no pooling with others

##### 2B. Aqua Protocol (External Shared Liquidity)

```solidity
// Use Aqua's shared liquidity layer for the same strategy bytecode
ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
    maker: maker,
    receiver: address(0),
    shouldUnwrapWeth: false,
    useAquaInsteadOfSignature: true
    // other MakerTraits args omitted for brevity
    // ...
    program: program
}));
// Requires prior: aqua.ship(token, amount)
```

**Storage:** Aqua protocol (external)  
**Setup:** Deposit to Aqua via `ship()`  
**Use Case:** Share liquidity across multiple strategies  
**Key Difference:** Unlike isolated dynamic balances, Aqua enables shared liquidity

See [Aqua Protocol](https://github.com/1inch/aqua) for details

### Maker Security

Your orders are protected by:

- **Authorization Mode** - EIP-712 signatures or Aqua balance mode (`useAquaInsteadOfSignature`)
- **Expiration Control** - Orders can expire at the time you define
- **Balance Limits** - Execution cannot exceed configured balances
- **Custom Receivers** - Control where settlement tokens are sent
- **Hooks** - Add custom validation/automation logic around transfers
- **Order Invalidation** - Prevent replay/overfill via bitmap or token-based invalidators

**Best Practices:**
- Always set expiration dates
- Use `_invalidateBit1D` for one-time orders
- Use `_invalidateTokenIn1D` / `_invalidateTokenOut1D` for partial-fill strategies
- Validate rates against market conditions before signing
- Add explicit rate protection (`_requireMinRate1D` or `_adjustMinRate1D`) when needed
- Treat instruction ordering as security-critical, especially around fee instructions
- Consider MEV protection (`_decayXD`) for AMM-style strategies

---

## For Takers (Swap Executors)

Takers execute swaps against maker orders to arbitrage or fulfill trades. This includes:

- **Finding profitable orders** to execute
- **Specifying swap amount** (either input or output)
- **Providing dynamic data** for adaptive instructions
- **Executing swaps** on-chain

### Executing a Swap

```solidity
// 1. Find an order to execute
ISwapVM.Order memory order = findProfitableOrder();

// 2. Build taker traits + data payload
bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
    taker: msg.sender,
    isExactIn: true,                        // You specify input amount
    shouldUnwrapWeth: false,                // Keep as WETH
    isStrictThresholdAmount: false,         // false = min/max threshold mode
    isFirstTransferFromTaker: false,
    useTransferFromAndAquaPush: false,
    threshold: abi.encodePacked(minAmountOut), // 32-byte min output for exactIn
    to: yourAddress,                        // Recipient override (or address(0))
    deadline: uint40(block.timestamp + 5 minutes),
    hasPreTransferInCallback: false,
    hasPreTransferOutCallback: false,
    preTransferInHookData: "",
    postTransferInHookData: "",
    preTransferOutHookData: "",
    postTransferOutHookData: "",
    preTransferInCallbackData: "",
    preTransferOutCallbackData: "",
    instructionsArgs: customInstructionArgs, // Data consumed by VM instructions
    signature: signature                      // Maker's order signature (empty for Aqua mode)
}));

// 3. Preview the swap (free call)
(uint256 quotedIn, uint256 quotedOut, bytes32 quotedOrderHash) = swapVM.asView().quote(
    order,
    USDC,           // Token you're paying
    WETH,           // Token you're receiving
    1000e6,         // Amount (input if isExactIn=true)
    takerData
);

// 4. Execute the swap with the same takerData
(uint256 actualIn, uint256 actualOut, bytes32 orderHash) = swapVM.swap(
    order,
    USDC,
    WETH,
    1000e6,        // Your input amount
    takerData
);
```

### Providing Dynamic Data

Some instructions read data from takers at execution time:

```solidity
// Pack custom data into TakerTraits.instructionsArgs
bytes memory customInstructionArgs = abi.encode(
    oraclePrice,    // For oracle-based adjustments
    maxGasPrice,    // For gas-sensitive orders
    userPreference  // Any custom parameters
);

// Instructions read it via:
// ctx.tryChopTakerArgs(32) - extracts 32 bytes
```

### Taker Security

Your swaps are protected by:

- **Threshold Validation** - Minimum output / maximum input (or strict exact threshold mode)
- **Slippage Protection** - Via threshold amounts
- **Custom Recipients** - Send tokens anywhere
- **Deadline Control** - Enforce taker-side expiration
- **Callbacks** - Pre-transfer callbacks for custom checks/integration
- **Quote Preview** - Check amounts before executing

**Best Practices:**
- Always use `quote()` before `swap()`
- Set appropriate thresholds for slippage
- Set `deadline` to bound execution time
- Use `isStrictThresholdAmount` only when exact threshold matching is required
- Reuse the same `takerData` between quote and swap
- Verify order hasn't expired
- Check for MEV opportunities
- Consider gas costs vs profit

---

## For Developers

Build custom instructions and integrate SwapVM into your protocols.

### Understanding the Execution Environment

#### The Context Structure

Every instruction receives a `Context` with three components:

```
Context
├── VM (Execution State)
│   ├── isStaticContext
│   │   - true during quote/static execution
│   │   - false during state-changing swap execution
│   ├── nextPC
│   │   - Program counter (MUTABLE, used by jumps)
│   ├── programPtr
│   │   - Bytecode currently being executed
│   ├── takerArgsPtr
│   │   - Taker dynamic data pointer (MUTABLE)
│   │   - Advanced via tryChopTakerArgs()
│   └── opcodes
│       - Available instruction array
│
├── SwapQuery (READ-ONLY)
│   ├── orderHash
│   │   - Unique order identifier
│   ├── maker
│   │   - Liquidity provider address
│   ├── taker
│   │   - Swap executor address
│   ├── tokenIn
│   │   - Input token address
│   ├── tokenOut
│   │   - Output token address
│   └── isExactIn
│       - Swap direction
│       - true = exact in, false = exact out
│
└── SwapRegisters (MUTABLE)
    ├── balanceIn
    │   - Maker available input-token balance
    ├── balanceOut
    │   - Maker available output-token balance
    ├── amountIn
    │   - Input amount
    │   - Taker provides OR VM computes
    ├── amountOut
    │   - Output amount
    │   - Taker provides OR VM computes
    └── amountNetPulled
        - Net amount pulled from maker
        - Used by fee/accounting logic
```

### Order Configuration (MakerTraits & TakerTraits)

```
MakerTraits (256-bit packed)
├── Bit Flags (bits 245-255)
│   ├── shouldUnwrapWeth (255)
│   │   - Unwrap WETH to ETH on output
│   ├── useAquaInsteadOfSignature (254)
│   │   - Use Aqua balance mode instead of signature
│   ├── allowZeroAmountIn (253)
│   │   - Allow zero amountIn (skip validation)
│   ├── hasPreTransferInHook (252)
│   ├── hasPostTransferInHook (251)
│   ├── hasPreTransferOutHook (250)
│   ├── hasPostTransferOutHook (249)
│   ├── preTransferInHookHasTarget (248)
│   ├── postTransferInHookHasTarget (247)
│   ├── preTransferOutHookHasTarget (246)
│   └── postTransferOutHookHasTarget (245)
│
├── Data Slices Indexes (bits 160-223, 64 bits)
│   └── Packed 4x uint16 offsets for hook slices
│
├── Program
│   └── Stored as the final tail in `order.data` (after hook slices)
│
└── Receiver (bits 0-159, 160 bits)
    └── Custom recipient address (0 = maker)
```

```
TakerTraits (Variable-length with 176-bit header)
├── Header (22 bytes packed)
│   ├── Slices Indexes (160 bits)
│   │   - 10x uint16 offsets for data slices
│   └── Bit Flags (16 bits)
│       ├── isExactIn (0)
│       │   - true = specify input, false = specify output
│       ├── shouldUnwrapWeth (1)
│       │   - Unwrap WETH to ETH on output
│       ├── hasPreTransferInCallback (2)
│       │   - Call taker callback before input transfer
│       ├── hasPreTransferOutCallback (3)
│       │   - Call taker callback before output transfer
│       ├── isStrictThresholdAmount (4)
│       │   - true = exact threshold, false = min/max mode
│       ├── isFirstTransferFromTaker (5)
│       └── useTransferFromAndAquaPush (6)
│           - SwapVM does transferFrom + Aqua push
│
└── Variable-length Data Slices
    ├── threshold (0 or 32 bytes)
    │   - Min output or max input
    ├── to (0 or 20 bytes)
    │   - Custom recipient
    ├── deadline (0 or 5 bytes)
    │   - Unix timestamp (uint40)
    ├── preTransferInHookData
    ├── postTransferInHookData
    ├── preTransferOutHookData
    ├── postTransferOutHookData
    ├── preTransferInCallbackData
    ├── preTransferOutCallbackData
    ├── instructionsArgs
    │   - Data consumed by VM instructions
    └── signature
        - EIP-712 signature for order
```

### Instruction Capabilities

Instructions primarily **compute swap amounts** and execution state. They do NOT perform the main final settlement transfers between maker and taker (that settlement happens in `SwapVM` after `runLoop()`), but some instructions can execute side effects such as protocol-fee transfers or external logic calls.

Instructions can modify these parts of the execution context:

#### 1. Swap Registers (`ctx.swap.*`)
All swap registers can be modified to calculate amounts and fee/accounting state:
- `balanceIn` / `balanceOut` - Set or adjust available balances for calculations
- `amountIn` / `amountOut` - Compute the missing swap amount
- `amountNetPulled` - Track net amount pulled from maker for fee/accounting flows

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
- ✅ Modify swap registers (including `amountNetPulled`)
- ✅ Change program counter for control flow
- ✅ Consume taker-provided data
- ✅ Read and write to their own storage mappings
- ✅ Make external calls (via `_extruction`)
- ✅ Execute fee transfers (protocol fee instructions)

**What Instructions CANNOT Do:**
- ❌ Modify query data (maker, taker, tokens, etc. - immutable)
- ❌ Execute the main maker<->taker settlement flow directly (handled by `SwapVM` after VM execution)
- ❌ Bypass SwapVM's validation (thresholds, signatures, etc.)
- ❌ Modify core SwapVM protocol state
- ❌ Execute after swap is complete

**Security Considerations:**
- Swap execution uses order-level transient reentrancy lock (`orderHash`) in `SwapVM.swap()`
- Gas limited by block and transaction
- External call risk is strategy-dependent (especially with `_extruction`)
- Deterministic execution is guaranteed only for deterministic instruction sets and deterministic external dependencies

### Building a Custom Router

SwapVM includes multiple routers for different purposes, each exposing a different instruction set:

- `SwapVMRouter` - General-purpose router with the full standard opcode set
- `LimitSwapVMRouter` - Limit-order-focused router (time-dependent and order-management instructions)
- `AquaSwapVMRouter` - Aqua-oriented router for shipped/shared-liquidity strategies

If you need a custom instruction set, create your own router by inheriting `SwapVM` plus your opcode contract and overriding `_instructions()`:

```solidity
contract MyRouter is SwapVM, Opcodes {
    constructor(address aqua, address weth, string memory name, string memory version)
        SwapVM(aqua, weth, name, version)
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

Every SwapVM program should be tested carefully before production use. Instruction composition and ordering can change pricing, invalidation behavior, quote/swap consistency, and security properties.

#### Recipe: test all invariants for a new SwapVM program

Use the provided `CoreInvariants` base contract:

- Build your program bytecode
- Build an order from that bytecode
- Prepare taker data for both exact-in and exact-out paths
- Run `assertAllInvariantsWithConfig(...)`

```solidity
contract MyInstructionTest is Test, OpcodesDebug, CoreInvariants {
    function test_MyProgram_AllInvariants() public {
        bytes memory program = buildMyProgram();
        ISwapVM.Order memory order = _createOrder(program);
        
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        // Optional tuning for strategy-specific behavior
        // config.skipAdditivity = true;
        // config.skipMonotonicity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }
}
```

#### Example: focused test for one program

```solidity
function test_MyProgram_QuoteMatchesSwap() public {
    bytes memory program = buildMyProgram();
    ISwapVM.Order memory order = _createOrder(program);

    bytes memory takerData = _signAndPackTakerData(order, true, 0);
    uint256 amount = 1e18;

    (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
        order, address(tokenA), address(tokenB), amount, takerData
    );

    uint256 snapshot = vm.snapshot();
    (uint256 swapIn, uint256 swapOut,) = swapVM.swap(
        order, address(tokenA), address(tokenB), amount, takerData
    );
    vm.revertTo(snapshot);

    assertEq(swapIn, quotedIn);
    assertEq(swapOut, quotedOut);
}
```

See `test/invariants/ExampleInvariantUsage.t.sol` for complete, up-to-date examples.

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
7. **Strategy Liveness** - Ensures a halted strategy can always resume execution

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

## 🚀 Getting Started

### Installation

```bash
npm install @1inch/swap-vm
# or
yarn add @1inch/swap-vm
```

### Quick Example

```solidity
import { SwapVMRouter } from "src/routers/SwapVMRouter.sol";

// Deploy router
SwapVMRouter router = new SwapVMRouter(
    aquaAddress,
    wethAddress,
    "MyDEX",
    "1.0"
);

// Create and execute orders...
```

### Resources

- **GitHub**: [github.com/1inch/swap-vm](https://github.com/1inch/swap-vm)
- **Documentation**: See `README.md`
- **Deployment Guide**: See `DEPLOY.md`
- **Testing Guide**: See `TESTING.md`
- **Tests**: Comprehensive examples in `/test`

---

## 📄 License

This project is licensed under the **LicenseRef-Degensoft-SwapVM-1.1**

See the [LICENSE](LICENSE) file for details.
See the [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) file for information about third-party software, libraries, and dependencies used in this project.

**Contact for licensing inquiries:**
- 📧 license@degensoft.com 
- 📧 legal@degensoft.com

