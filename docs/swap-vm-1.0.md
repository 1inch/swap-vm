# 1inch SwapVM

## Swap virtual machine

**Authors:**

| | |
|---|---|
| Anton Bukov — k06aaa@gmail.com | Sergej Kunz — info@deacix.de |
| Gleb Alekseev — alekseev.gleb@gmail.com | Sergey Prilutskiy — prilutski@gmail.com |
| Vadim Fadeev — xboxfadeev@gmail.com | |

**Version:** Release 1.0
**Repository:** https://github.com/1inch/swap-vm

---a

## Abstract

Current AMM architectures tightly couple swap curve mathematics with fee logic and settlement infrastructure. This forces developers to duplicate and re-audit code for every new design, increasing the attack surface. SwapVM addresses these issues by allowing developers to focus solely on mathematical models, while the VM provides shared, audited infrastructure and separates curves, fees, and execution control into composable instructions. The instruction set includes pre-built curves and fee structures covering the most common AMM designs available today. Formally defined invariants guarantee that any instruction, existing or new, composes correctly and securely with the rest of the system. The same bytecode executes in both swap and read-only quoting modes, providing 100% accurate off-chain simulation. When integrated with 1inch's Aqua shared liquidity layer, SwapVM enables market makers to run multiple AMM strategies from a single capital pool without fragmenting liquidity, improving capital efficiency.

---

## 1 Introduction

Modern AMMs and DEXes have reached significant maturity, yet their architectures still tightly couple three concerns that could be independent: swap curve mathematics, fee logic, and settlement infrastructure.

First, every new AMM design requires developers to reimplement settlement, authorization, and token-transfer code alongside the mathematical model. Even minor errors in this duplicated infrastructure can lead to severe vulnerabilities, as demonstrated by multiple incidents where infrastructure-level bugs in DEX contracts led to significant losses.[^1] Recent protocols have made progress toward separating these concerns — Balancer V3 [4] separates its Vault (token accounting and settlement) from Pool contracts (swap math), and Uniswap V4 [5] introduces hooks that run custom logic around swaps. However, in both cases creating a new AMM still requires deploying custom smart contract code, and curve math and fee logic remain coupled within each contract. Existing audited components cannot be recomposed into new configurations without writing and auditing new code.

Second, fee logic is typically embedded within the swap curve itself. Changing a fee structure means modifying or re-auditing the core swap math, limiting experimentation with fee models and increasing the risk of introducing errors.

A further consequence of this tight coupling is the difficulty of maintaining accurate off-chain swap quoting. As AMM designs grow more complex — incorporating dynamic fees, time-dependent logic, or multi-step calculations — the quote function is often implemented separately from the swap function. Any divergence between the two leads to unreliable routing, unpredictable execution for users, and ongoing maintenance burden to keep both paths in sync.

Beyond these architectural concerns, capital efficiency suffers when each AMM locks its own liquidity pool, fragmenting capital across strategies.

[^1]: Notable examples include: BurgerSwap (2021), where a single missing line of code led to a $7.2M exploit [1]; ParaSwap Augustus V6 (2024), where a vulnerability in swap callback handling caused ~$1.4M in losses [2]; and KyberSwap Elastic (2023), where a rounding error in tick-based swap logic led to ~$48.7M stolen [3].

---

## 2 SwapVM overview

The fundamental design principle of SwapVM is that AMM mathematics can be decomposed into two kinds of components: base curves and transformations. A base curve defines the fundamental pricing function — such as constant product, a pegged asset curve, or time-decaying virtual reserves. A transformation modifies how a base curve behaves — for example, concentrating liquidity within a price range, or applying a fee. A maker builds an AMM strategy by selecting a base curve and layering one or more transformations on top of it. New base curves and new transformations can be developed independently and combined to produce entirely new AMM designs. A set of formally defined invariants (Section 4) ensures that any instruction satisfying them composes correctly and securely with existing ones.

SwapVM implements this decomposition as a bytecode virtual machine on the EVM. Each base curve and each transformation is an instruction. Beyond mathematical components, SwapVM includes control flow instructions — conditional jumps, deadlines, and access restrictions — making programs fully programmable rather than fixed pipelines. Instructions are composed into programs — compact bytecode sequences that define a complete AMM strategy. This design gives makers maximum flexibility in constructing AMMs, but not all combinations of base curves and transformations are compatible; composing them correctly requires understanding the mathematical properties of each component. In this sense, building a SwapVM program is analogous to writing a program in machine opcodes: expressive and powerful, but demanding precision from the author.

**Key features of SwapVM:**

- SwapVM provides fixed, shared settlement infrastructure, while swap curves and fee structures are independent, composable building blocks that can be extended with new instructions.
- The instruction set includes base curves and transformations covering the most common AMM designs available today.
- The same bytecode executes in both swap and read-only quoting modes, delivering 100% accurate off-chain simulation.
- Programs are serializable and identifiable by their bytecode hash, enabling reuse and unique order identification.
- Each instruction can be audited independently; new instructions do not require re-auditing existing ones.

---

## 3 Architecture

Section 2 introduced the decomposition of AMM mathematics into base curves and transformations as SwapVM's fundamental design principle. This section describes the architecture that realizes this decomposition: the execution context that provides shared infrastructure for all instructions, the execution model that enables transformations to wrap base curves through nested dispatch, and the bytecode encoding that makes programs compact and serializable.

### 3.1 Execution context

Every instruction executes within a `Context` (Figure 1) that consists of three components:

1. **VM state (execution control)** — contains the program counter `nextPC`, the bytecode pointer, the taker-args pointer for reading dynamic data supplied by the taker at swap time, the opcode table, and a static-context flag that distinguishes quote (read-only) from swap (state-changing) execution.
2. **SwapQuery (read-only)** — immutable per-swap metadata set during initialization: order hash, maker and taker addresses, input and output token addresses, and the `isExactIn` direction flag.
3. **SwapRegisters (mutable swap state)** — the registers that instructions read and write to compute swap outcomes.

This three-part structure directly addresses the coupling problems identified in Section 1. The shared VM state (execution loop, opcode dispatch, register interface) decouples swap mathematics from infrastructure — developers write only the mathematical logic of an instruction while the VM handles execution, settlement, and authorization. The separation of SwapQuery from SwapRegisters ensures that per-swap metadata remains immutable while instructions freely compose over mutable state. The third form of coupling — strategies bound to individual liquidity pools — is addressed through Aqua integration (Section 6).

SwapVM exposes six registers to instructions:

- `balanceIn` — current balance of the input token
- `balanceOut` — current balance of the output token
- `amountIn` — computed input amount for the swap
- `amountOut` — computed output amount for the swap
- `amountNetPulled` — net amount pulled from the maker, used by fee and accounting instructions
- `nextPC` — program counter indicating which instruction executes next

The first five registers hold mutable swap state and reside in the `SwapRegisters` struct. The program counter `nextPC` resides in the VM state struct but is exposed to instructions as a writable register, enabling control flow operations such as jumps. The register set is designed to be extensible: future versions may introduce additional registers to support new instruction categories.

#### Figure 1. SwapVM Architecture and Execution Flow

##### Context layout

Runtime (SwapVM) on the left; pointed-to memory on the right.

```
┌─ SwapVM ─────────────────────────────────────────────────────────────┐
│  swap query data ────── data pointer ──────► │ SwapQuery data        │
│  program pointer ───── program pointer ────► │ SwapVM program        │
│                                              │  1: SetBalances()     │
│  ┌─ SwapVM registers ─────────────────────┐  │  2: ApplyFee()        │
│  │ program counter: 2                     │  │  3: calcSwap()  ◄──┐  │
│  │ balanceIn: 10000000  balanceOut: 10M   │  │  ...               │  │
│  │ amountIn: 100        amountOut: 0      │  └────────────────────┼──┘
│  │ amountNetPulled: 0                     │                       │  |
│  │ nextPC: 2 ─────────── nextPC ──────────┼───────────────────────┘  |
│  └────────────────────────────────────────┘                          |
└──────────────────────────────────────────────────────────────────────┘
```

##### Structured equivalent

```text
SwapVM {
  pointers:
    swap query data  --[data pointer]-->  SwapQuery data (read-only)
      • amountIn = 100
      • amountOut = 0
      • ...

    program pointer  --[program pointer]-->  SwapVM program (bytecode)
      • instruction 1: SetBalances()
      • instruction 2: ApplyFee()
      • instruction 3: calcSwap()    # example: nextPC may point here
      • ...

  SwapVM registers (mutable):
    program counter: 2
    balanceIn:  10000000    |    balanceOut: 10000000
    amountIn:   100          |    amountOut:    0
    amountNetPulled: 0
    nextPC: 2  --[nextPC]-->  current instruction in program
}
```

##### Three-part Context (companion to the figure)

Every instruction runs inside a `Context` with three components:

| Component | Role | Mutable? |
|-----------|------|----------|
| **VM state** | `nextPC`, bytecode pointer, taker-args pointer, opcode table, static-context flag (quote vs swap) | Control fields yes |
| **SwapQuery** | Order hash, maker/taker addresses, token addresses, `isExactIn` | No (read-only) |
| **SwapRegisters** | `balanceIn`, `balanceOut`, `amountIn`, `amountOut`, `amountNetPulled` | Yes |

`nextPC` lives in VM state but is exposed to instructions as a writable register (jumps, control flow).

### 3.2 Execution model

SwapVM has two entry points that share the same execution core. The `swap()` function verifies authorization through Aqua's balance management system, initializes the `Context`, loads initial values into registers, and begins execution. The `quote()` function executes the same program in a read-only (static) context, enabling 100% accurate off-chain swap simulation without any state changes. Because both entry points execute identical bytecode through the same `runLoop()`, the quoting divergence problem described in Section 1 is eliminated by design.

The `isExactIn` flag determines the swap direction: when true, the taker specifies a fixed input amount and the VM computes the output; when false, the taker specifies a fixed output amount and the VM computes the required input. Every instruction respects this flag, ensuring correct behavior in both directions from the same bytecode.

After initialization, execution enters the `runLoop()` procedure, which iterates through the bytecode and dispatches each instruction sequentially. Without it, every combination of balance-loading, fee, curve, and validation would require a separate contract or hardcoded function. `runLoop()` lets makers compose arbitrary instruction sequences from bytecode instead.

The two kinds of components introduced in Section 2 map directly to two execution patterns. Base curve instructions (such as the constant-product swap) execute in a single pass: they read the current register state, compute swap amounts, and write the results. Transformation instructions use a wrapping pattern: they adjust registers, delegate to the remaining program via a nested `runLoop()` call, and finalize after the inner program completes. This nesting works because `nextPC` is advanced past the current instruction before it executes, so a nested `runLoop()` call picks up at the next instruction and runs through the end of the program. No instruction needs to know what follows it — any fee can wrap any curve without either being modified. The nesting mechanism is illustrated in Figure 3.

Control flow instructions modify `nextPC` to jump to arbitrary bytecode positions, enabling conditional logic and branching. Combined with the wrapping pattern, this makes SwapVM programs fully programmable rather than fixed pipelines.

To illustrate, consider a minimal AMM program consisting of two instructions: `_flatFeeAmountInXD` wrapping `_xycSwapXD` (a constant-product swap). Suppose the maker's pool holds `balanceIn = 10000` and `balanceOut = 10000`, and a taker submits an exactIn swap with `amountIn = 100`.

1. `runLoop()` dispatches `_flatFeeAmountInXD` (the fee instruction). It reduces `amountIn` by the fee (e.g. 1%, leaving 99), then calls `runLoop()` on the remaining bytecode.
2. The nested `runLoop()` dispatches `_xycSwapXD`. Using the constant-product formula with the adjusted input, it computes `amountOut` and writes it to the register.
3. Control returns to the fee instruction, which finalizes (restoring the original `amountIn`).
4. `runLoop()` completes and the VM returns the pair `(amountIn, amountOut)`.

The same bytecode handles the reverse direction: with `isExactIn = false`, the fee instruction delegates inward first, the swap curve computes the required `amountIn`, and the fee instruction adds the fee to `amountIn` after the nested `runLoop()` returns. This is why wrapping is essential rather than flat sequential execution — in the exactOut direction, the fee can only be computed after the curve has determined the base input, and the wrapping pattern handles this naturally without special-casing each fee-curve combination.

Figure 2 shows a more complete example of this pattern: a four-instruction Aqua AMM where the protocol fee wraps liquidity concentration, a flat maker fee, and a constant-product swap, each nesting into the next via `runLoop()`.

#### Figure 2: SwapVM Bytecode: each instruction is encoded as `[opcode: 1 byte][params_length: 1 byte][params: N bytes]`. The example shows an Aqua AMM program with nested wrapping fees: the protocol fee wraps liquidity concentration, a flat maker fee, and a constant-product swap. Nesting is expressed visually via subgraphs — each outer instruction's `runLoop()` dispatches the inner program enclosed within it.

##### Per-instruction layout

```text
[ opcode (1 B) ][ params_length (1 B) ][ params (N B) ]
```

##### Example program (Aqua AMM)

| # | Instruction | opcode | length | params |
|---|-------------|--------|--------|--------|
| 1 | `_aquaProtocolFeeAmountInXD` | `0x1C` | `0x18` | `feeBps`, `to` (24 bytes) |
| 2 | `_xycConcentrateGrowLiquidity2D` | `0x12` | `0x40` | `sqrtP_min`, `sqrtP_max` (64 bytes) |
| 3 | `_flatFeeAmountInXD` | `0x15` | `0x04` | `feeBps` (4 bytes) |
| 4 | `_xycSwapXD` | `0x11` | `0x00` | (none) |

##### Linear byte stream

```text
[0x1C][0x18][ feeBps, to ...     ]
[0x12][0x40][ sqrtP_min, max ... ]
[0x15][0x04][ feeBps            ]
[0x11][0x00]
```

##### Nesting via `runLoop()` (logical structure)

Outer instructions wrap the **tail** of the program. Braces in the paper denote these inner programs:

```text
_aquaProtocolFeeAmountInXD
└── inner program (runLoop):
    _xycConcentrateGrowLiquidity2D
    └── inner program (runLoop):
        _flatFeeAmountInXD
        └── inner program (runLoop):
            _xycSwapXD
```

Mapping to the linear stream:

```text
[0x1C ...]  wraps everything from [0x12] onward
    [0x12 ...]  wraps everything from [0x15] onward
        [0x15 ...]  wraps [0x11][0x00]
            [0x11][0x00]  base curve (leaf)
```


#### Figure 3: SwapVM nested `runLoop()`: the wrapping pattern. The fee instruction adjusts registers, delegates to the remaining program via `runLoop()`, and finalizes after the inner program completes.

##### Program when `_flatFeeAmountInXD` executes

```text
SwapVM program (remaining bytecode):
  1. _flatFeeAmountInXD()     ← currently executing
  2. _xycSwapXD()              ← inner program (tail after advance of nextPC)
```

##### Execution steps

```text
_flatFeeAmountInXD execution:

  1. adjust registers
       amountIn -= fee

  2. delegate to inner program
       ctx.runLoop()
         ├─ dispatch ──►  _xycSwapXD()   (runs instructions 2..end)
         └─ return  ◄───  inner program complete

  3. finalize
       amountIn = original
```

##### Invariant

Before a wrapping instruction runs, `nextPC` is advanced **past** that instruction. A nested `runLoop()` therefore starts at the **next** instruction and runs through end-of-program. The wrapper does not need to know what follows (any fee can wrap any curve).

##### Base curve vs transformation

| Kind | Pattern | Example |
|------|---------|---------|
| **Base curve** | Single pass: read registers → compute → write | `_xycSwapXD` |
| **Transformation** | Adjust → `runLoop()` on tail → finalize | `_flatFeeAmountInXD`, fees, concentrate |

##### Sequence view (optional Mermaid)

```mermaid
sequenceDiagram
  participant Fee as _flatFeeAmountInXD
  participant Loop as ctx.runLoop()
  participant Swap as _xycSwapXD

  Fee->>Fee: amountIn -= fee
  Fee->>Loop: runLoop()
  Loop->>Swap: dispatch inner program
  Swap-->>Loop: return
  Loop-->>Fee: inner complete
  Fee->>Fee: amountIn = original
```

##### Entry points (related, not a separate figure)

| Function | Authorization | Context | Effect |
|----------|---------------|---------|--------|
| `swap()` | Aqua balance management | state-changing | Executes bytecode, settles |
| `quote()` | none (simulation) | static / read-only | Same bytecode via same `runLoop()`, no state change |

Both paths share the same execution core, so quotes match on-chain execution for the same bytecode and inputs.



### 3.3 Bytecode encoding

Every instruction is composed of an opcode (a 1-byte identifier mapped to an EVM function) and parameters. The bytecode format is: `[opcode: 1 byte][params_length: 1 byte][params: N bytes]`. For instance, the fee size in basis points is a parameter for the `flatFee()` instruction, included directly in the bytecode. The structure of a complete SwapVM program is illustrated in Figure 2.

All SwapVM instructions share a unified interface and operate within the SwapVM `Context`. SwapVM uses a suffix convention to indicate the number of tokens an instruction operates on: "2D" instructions are optimized for exactly two tokens, while "XD" instructions support an arbitrary number. Version 1.0 focuses on two-token AMMs, so 2D instructions are the primary building blocks, with XD instructions used in their two-token capacity. The instruction set is designed to be extended with new opcodes in future versions.

---

## 4 Core invariants

Section 2 noted that composability requires formally defined invariants so that any instruction — existing or new — composes correctly and securely with the rest of the system. This section defines the seven invariants that every SwapVM instruction must satisfy.

1. **Exact In/Out Symmetry.** Every instruction must maintain symmetry between exactIn and exactOut swaps: if `exactIn(X) → Y`, then `exactOut(Y) → X` within rounding tolerance. This prevents internal arbitrage and ensures price consistency.
2. **Swap Additivity.** Splitting a trade into smaller parts can yield less output (subadditive), more output (superadditive), or the same output (strictly additive) compared to a single trade. Superadditive behavior is dangerous because it creates a profitable order-splitting arbitrage. Strict additivity is the theoretical ideal — there is no incentive to split or combine trades. In practice, AMM curves are naturally subadditive due to their curvature, which is acceptable: splitting yields less, so there is no advantage to splitting.
3. **Quote/Swap Consistency.** The read-only `quote()` function and the state-changing `swap()` function must return identical amounts for the same inputs, ensuring MEV protection and predictable execution.
4. **Price Monotonicity.** Larger trades must receive equal or worse prices: the ratio `amountOut/amountIn` must not increase as trade size increases, preserving natural market dynamics.
5. **Rounding Favors Maker.** All rounding operations favor the maker: `amountIn` rounds up (ceil) and `amountOut` rounds down (floor), protecting liquidity providers from rounding-based value extraction.
6. **Balance Sufficiency.** Trades cannot exceed available liquidity: execution must revert if the computed `amountOut` exceeds `balanceOut`, preventing impossible trades and protecting order integrity.
7. **Strategy Liveness.** AMM strategies must remain live even when one reserve is temporarily depleted. Reverse-direction swaps must still be possible and able to restore depleted reserves, returning the strategy to a working state.

Some of these invariants are enforced by the VM architecture itself — for example, Quote/Swap Consistency is guaranteed by the shared `runLoop()` that both entry points execute. Others, such as Rounding Favors Maker and Price Monotonicity, are requirements that each instruction must satisfy in its implementation. All invariants are validated through comprehensive test suites, and any new instruction must maintain them.

---

## 5 SwapVM instructions

Below is an overview of SwapVM's core instructions; detailed specifications will be covered in the technical documentation. The instruction set described here will expand in future releases of SwapVM. Additionally, some helper and debugging instructions, which assist in developing SwapVM programs, have been omitted for brevity.

### 5.1 Controls

This group of instructions manages the program counter and enforces execution constraints, enabling conditional logic, flow control, and access restrictions in SwapVM programs. Instructions include:

- `_jump()` unconditionally sets the program counter to a specified position, enabling branching within the bytecode
- `_jumpIfTokenIn()` conditionally jumps if the input token matches a specified token address
- `_jumpIfTokenOut()` conditionally jumps if the output token matches a specified token address
- `_deadline()` reverts execution if the current block timestamp exceeds a specified deadline
- `_salt()` a no-op instruction whose parameters contribute to the program's bytecode hash, enabling unique order identification for otherwise identical programs
- `_onlyTakerTokenBalanceNonZero()` validates that the taker (the person executing the swap) holds at least some amount of a specified token (natively supports ERC-721 NFTs)
- `_onlyTakerTokenBalanceGte()` validates that the taker holds at least a minimum amount of a specified token
- `_onlyTakerTokenSupplyShareGte()` validates that the taker holds at least a certain percentage of the token's total supply

The `_deadline()` instruction enables time-limited strategies, while `_salt()` allows makers to create multiple distinct orders with otherwise identical logic. The jump instructions enable conditional swaps, such as selecting different instruction sequences or fee structures based on which token is the input. The taker-gating instructions (`_onlyTakerTokenBalance*`) allow makers to restrict who can execute their orders based on token holdings.

### 5.2 External call

The `_extruction()` instruction allows the SwapVM program to perform an external call, effectively integrating external logic of almost any complexity. This extends SwapVM's functionality and enables integration with DeFi protocols. However, this instruction demands careful handling to ensure security. A typical use case would be incorporating external oracle prices into swap calculations.

### 5.3 Swap and AMM

These instructions implement swap curve mathematics. Following the taxonomy introduced in Section 2, they divide into base curves (single-pass instructions that compute swap amounts) and transformations (wrapping instructions that modify how a base curve behaves via nested `runLoop()` calls).

**Base curves:**

- `_xycSwapXD()`: implements a constant-product AMM swap [6] (`x * y = k`)
- `_peggedSwapGrowPriceRange2D()`: implements a square-root linear curve optimized for pegged assets such as stablecoins and wrapped tokens. It uses the formula $\sqrt{x/X_0} + \sqrt{y/Y_0} + A \cdot (x/X_0 + y/Y_0) = 1 + A$, where the linear width parameter $A$ controls how flat the curve is near the 1:1 price and supports tokens with different decimals via rate multipliers

**Transformations:**

- `_xycConcentrateGrowLiquidity2D()` [7]: computes virtual reserves from real balances and price bounds, making the pool behave as if it has more liquidity within the specified range (optimized for two tokens). The liquidity parameter `L` is recomputed from real balances on each swap, so when fee revenue grows real balances, `L` increases automatically — achieving fee reinvestment without explicit logic
- `_decayXD()`: implements a time-decaying virtual reserve offset that provides MEV protection; after each swap, the opposite-direction balance is penalized by the swap amount, and this penalty decays linearly over a configurable period, discouraging sandwich attacks [8] by making immediate reverse swaps less favorable

Base curves and transformations compose through the wrapping pattern described in Section 3.2: transformations adjust registers, delegate to the inner program, and finalize. A typical AMM program layers one or more transformations around a base curve.

### 5.4 Fees

Fee instructions configure and apply various fee structures to in/out amounts, enabling AMMs with flexible fee models. All fee instructions are wrapping instructions (Section 3.2): they adjust the relevant amount, delegate execution to the inner program via `runLoop()`, and then finalize. This design ensures fees compose correctly regardless of the swap direction. Instructions include:

- `_flatFeeAmountInXD()` applies a flat percentage fee to the input amount
- `_protocolFeeAmountInXD()` applies a flat fee on input amount and transfers it to a protocol address
- `_aquaProtocolFeeAmountInXD()` applies a flat fee on input amount and transfers it to a protocol address using Aqua's `pull()` function
- `_dynamicProtocolFeeAmountInXD()` queries an external fee provider contract via `staticcall` for the fee rate and recipient, then applies the fee to the input amount
- `_aquaDynamicProtocolFeeAmountInXD()` same as above but transfers the fee via Aqua's `pull()` function

Flat fees deduct a fixed percentage from the input amount. Dynamic protocol fees allow external contracts to determine fee rates at execution time, enabling governance-controlled or market-adaptive fee models. The Aqua variants use Aqua's `pull()` function for fee transfer, keeping fees within the Aqua balance system.

### 5.5 Canonical instruction ordering

Instruction order within a program is security-critical. The same instructions in a different order can change pricing, settlement amounts, and economic outcomes. For AMM strategies, the canonical ordering ensures correct protocol-fee isolation, liquidity growth, and conservation laws.

For **Aqua-backed AMMs** (where balances are managed externally by Aqua), the canonical order is:

```
[protocolFee] → [transformation] → [fee] → baseCurve → [salt]
```

For example, a concentrated-liquidity Aqua AMM with fees:

```
aquaProtocolFee → concentrate → flatFee → xycSwap → salt
```

The protocol fee is placed first so it is extracted from `amountIn` before balances are touched, cleanly isolating fee revenue from pool reserves. The flat fee is placed after concentration so that the retained fee amount grows liquidity correctly. The key conservation invariant is:

$$\texttt{pool\_balance} + \texttt{protocol\_fee} = \texttt{initial\_balance} + \texttt{total\_amountIn}$$

---

## 6 Conclusion

Section 1 identified a third form of coupling in current AMM architectures: each strategy locks its own liquidity pool, fragmenting capital across markets. 1inch's Aqua shared liquidity layer addresses this directly. With Aqua, makers back multiple SwapVM strategies from a single balance — strategies can be created, reconfigured, or removed without moving capital. From the taker's perspective, each strategy behaves as a regular AMM where swaps draw actual tokens from the maker's Aqua balance. SwapVM provides dedicated Aqua instructions for fee settlement (Section 5.4) and a canonical instruction ordering for Aqua-backed AMMs (Section 5.5). The full Aqua protocol design is detailed in the Aqua whitepaper [9].

SwapVM provides a rigorous foundation for building and verifying token swap strategies. Its three-part execution context (VM state, read-only swap query, and mutable swap registers), direction-aware execution model (`isExactIn`), wrapping pattern for composable transformations, and formally defined core invariants ensure that any instruction — existing or new — composes correctly and securely with the rest of the system. Version 1.0 of the instruction set delivers constant-product AMMs, concentrated liquidity with automatic fee reinvestment, time-decaying virtual reserves for MEV protection, and pegged asset swap curves — all expressible as composable bytecode programs. Canonical instruction orderings ensure correct fee isolation and conservation laws.

The instruction set is designed to be extensible: new opcodes can be added to support emerging curve designs and trading strategies without modifying the VM core. Future versions will expand XD instructions to their full multi-token capacity, enabling strategies that operate across more than two tokens.

---

## References

[1] *Missing line of code leads to $7.2 million exploit of DEX BurgerSwap.* The Block, 2021. Available: https://www.theblock.co/post/106457/missing-line-of-code-leads-to-7-2-million-exploit-of-dex-burgerswap.

[2] Velora. *Post mortem: Augustus V6 vulnerability of March 20th, 2024.* Medium, 2024. Available: https://veloradex.medium.com/post-mortem-augustus-v6-vulnerability-of-march-20th-2024-5df663a4bf01.

[3] KyberSwap. *Post mortem: KyberSwap elastic exploit November 2023.* KyberSwap Blog, 2023. Available: https://blog.kyberswap.com/post-mortem-kyberswap-elastic-exploit/.

[4] Fernando Martinelli. *Balancer v3: The vault.* Balancer Protocol, 2024. Available: https://docs.balancer.fi/concepts/vault/.

[5] Hayden Adams, Sara Reynolds, Noah Zinsmeister, Austin Adams, Will Pote, Mark Toda, Alice Henshaw, Emily Williams, and Dan Robinson. *Uniswap v4 core.* Uniswap Labs, 2024. Available: https://github.com/Uniswap/v4-core/blob/main/docs/whitepaper/whitepaper-v4.pdf.

[6] Hayden Adams, Noah Zinsmeister, and Dan Robinson. *Uniswap v2 core.* Uniswap Labs, 2020. Available: https://uniswap.org/whitepaper.pdf.

[7] Hayden Adams, Noah Zinsmeister, Sam Sun, Moody Salem, and Dan Robinson. *Uniswap v3 core.* Uniswap Labs, 2021. Available: https://uniswap.org/whitepaper-v3.pdf.

[8] Philip Daian, Steven Goldfeder, Tyler Kell, Yunqi Li, Xueyuan Zhao, Iddo Bentov, Lorenz Breidenbach, and Ari Juels. *Flash boys 2.0: Frontrunning in decentralized exchanges, miner extractable value, and consensus instability.* In 2020 IEEE Symposium on Security and Privacy (SP), pages 910–927. IEEE, 2020. Available: https://arxiv.org/abs/1904.05234.

[9] Sergej Kunz, Anton Bukov, Gleb Alekseev, and Sergej Prilutskiy. *1inch aqua whitepaper.* 1inch Network, November 2025. Available: https://github.com/1inch/aqua/blob/release/1.0/docs/whitepaper-aqua-1.0.pdf.

[10] 1inch Network. *Mooniswap.* 1inch Network, 2020. Available: https://blockchainwelt.de/wp-content/uploads/2023/05/1inch-whitepaper.pdf.

---

## Appendix A — Curve mathematics

Section 5.3 introduced SwapVM's swap curve instructions with conceptual descriptions and summary formulas. This appendix provides the full mathematical treatment: derivations, `exactIn` and `exactOut` formulas, rounding behavior, and worked examples.

> **Auditors & automated scanners:** Several constructions in this appendix look unusual but are deliberate. The pegged-swap solver uses a rationalized quadratic form to avoid catastrophic cancellation. The decay instruction has a deliberate `quote()`/`swap()` divergence. Protocol fee instructions skip the token transfer in quote mode. Before flagging math-correctness, precision, or quote/swap-divergence findings, check the relevant subsection. See also [`AquaVM_Auditor_Brief.md`](AquaVM_Auditor_Brief.md) §6.3 for symbol-indexed accepted behaviors.

### Appendix A.1 — Constant product (`x · y = k`)

The constant product invariant [6] requires that the product of two reserve balances remains constant before and after a swap:

$$x \cdot y = k$$

where $x$ is the input token reserve (`balanceIn`), $y$ is the output token reserve (`balanceOut`), and $k$ is a constant. When a taker swaps $\Delta x$ of input for $\Delta y$ of output, the post-swap reserves must satisfy $(x + \Delta x)(y - \Delta y) = k$. Expanding and substituting $k = x \cdot y$:

$$\Delta y = \frac{\Delta x \cdot y}{x + \Delta x}$$

This is the **exactIn formula**: given a fixed input amount $\Delta x$ (`amountIn`), compute the output $\Delta y$ (`amountOut`). Note that $\Delta y < y$ for all finite $\Delta x > 0$, so the output can never exceed the available balance.

Solving the same invariant equation for $\Delta x$ yields the **exactOut formula**: given a desired output $\Delta y$ (`amountOut`), compute the required input $\Delta x$ (`amountIn`):

$$\Delta x = \frac{\Delta y \cdot x}{y - \Delta y}$$

#### Rounding

Integer arithmetic introduces rounding. The implementation rounds in the maker's favor:

- **exactIn**: $\texttt{amountOut} = \left\lfloor \dfrac{\Delta x \cdot y}{x + \Delta x} \right\rfloor$ — taker receives less
- **exactOut**: $\texttt{amountIn} = \left\lceil \dfrac{\Delta y \cdot x}{y - \Delta y} \right\rceil$ — taker pays more

#### Preconditions

The instruction requires both balances to be non-zero (`x > 0` and `y > 0`), since `k = 0` would make the pricing formula degenerate. A **recompute guard** prevents double-computation: in exactIn mode the instruction requires `amountOut == 0` on entry, and in exactOut mode it requires `amountIn == 0`.

#### Invariant compliance

1. **Exact In/Out Symmetry.** Both formulas are algebraic rearrangements of the same equation `(x + Δx)·(y − Δy) = x · y`. If `exactIn(Δx) → Δy`, then substituting `Δy` into the exactOut formula recovers `Δx` within rounding tolerance (one direction floors, the other ceils).
2. **Swap Additivity.** The constant product curve is strictly subadditive: splitting a trade of size `Δx` into two parts `Δx₁ + Δx₂` always yields less total output than a single trade of `Δx`. This follows from the curve's convexity — each partial trade moves the price against the taker, making subsequent parts more expensive. There is no profitable order-splitting.
3. **Quote/Swap Consistency.** The instruction is a pure function over registers — it reads balances and amounts, computes, and writes back. It performs no storage reads or state-dependent operations, so `quote()` and `swap()` produce identical results.
4. **Price Monotonicity.** The effective price `Δy / Δx = y / (x + Δx)` is a decreasing function of `Δx`. Larger trades receive strictly worse prices.
5. **Rounding Favors Maker.** As described above: exactIn floors `amountOut` (taker receives at most the theoretical amount), exactOut ceils `amountIn` (taker pays at least the theoretical amount).
6. **Balance Sufficiency.** From the exactIn formula, `Δy = Δx · y / (x + Δx) < y` for all finite `Δx > 0`. The computed output is always strictly less than `balanceOut`, so the trade can always be settled.
7. **Strategy Liveness.** The exactIn formula requires both reserves to be non-zero and reverts cleanly otherwise. Liveness is maintained at the strategy level: when one reserve is depleted through trading, the reverse-direction swap remains possible (since the other reserve is non-zero) and can restore the depleted reserve.

#### Composability

The constant product instruction is a **base curve**: it executes in a single pass with no nested `runLoop()` call. It reads `balanceIn`, `balanceOut`, and one of the amount registers from the context, computes the other amount via the formula above, and writes it back. This makes it agnostic to what preceded it in the program. Transformations such as concentrated liquidity modify the balance registers before this instruction runs; fees modify the amount registers. The constant product formula operates on whatever register values it receives. The recompute guard prevents accidental double-invocation within the same program.

---

### Appendix A.2 — Concentrated liquidity with fee reinvestment

Concentrated liquidity focuses a maker's capital within a price range `[P_min, P_max]`, making the pool behave as if it has more liquidity than the real balances alone. The instruction achieves this by computing **virtual reserves** and adding them to the balance registers before the inner base curve executes. Because the liquidity parameter `L` is recomputed from real balances on every swap, fee revenue that grows real balances automatically increases `L` — achieving fee reinvestment without any explicit reinvestment logic.

#### Virtual reserves

Following the Uniswap V3 concentrated liquidity model [7], the virtual reserves within a price range are defined as:

$$x_v = x + \frac{L}{\sqrt{P_{\max}}}, \qquad y_v = y + L \cdot \sqrt{P_{\min}}$$

where $x$ is the real balance of the lower-address token (`tokenLt`), $y$ is the real balance of the higher-address token (`tokenGt`), and $L$ is the liquidity parameter. The virtual reserves satisfy the constant product invariant $x_v \cdot y_v = L^2$, so after adding them to the balance registers, the inner constant-product swap operates on inflated balances that represent the concentrated position.

#### Computing L from real balances

Given real balances $(x, y)$ and price bounds $(\sqrt{P_{\min}}, \sqrt{P_{\max}})$, $L$ is determined by solving $x_v \cdot y_v = L^2$. Substituting the virtual reserve definitions and expanding:

$$\left(x + \frac{L}{\sqrt{P_{\max}}}\right) \cdot \left(y + L \cdot \sqrt{P_{\min}}\right) = L^2$$

Rearranging into a quadratic in $L$:

$$\alpha \cdot L^2 - \beta \cdot L - x \cdot y = 0$$

where:

$$\alpha = 1 - \frac{\sqrt{P_{\min}}}{\sqrt{P_{\max}}}, \qquad \beta = x \cdot \sqrt{P_{\min}} + \frac{y}{\sqrt{P_{\max}}}$$

Applying the quadratic formula and taking the positive root:

$$L = \frac{\beta + \sqrt{\beta^2 + 4\alpha \cdot x \cdot y}}{2\alpha}$$

This is computed on every swap from the current real balances, so $L$ always reflects the pool's actual state.

#### Execution flow

The instruction executes as a wrapping transformation:

1. **Parse price bounds** `sqrt(P_min)` and `sqrt(P_max)` from the instruction arguments.
2. **Determine token ordering**: `isTokenInLt` = whether `tokenIn` has the lower address.
3. **Compute `L`** from real balances using the quadratic formula above.
4. **Add virtual reserves to balance registers.** For the input side: `ceil(L / sqrt(P_max))` (maker gets more virtual input balance). For the output side: `floor(L · sqrt(P_min))` (less virtual output balance).
5. **Call `runLoop()`** to delegate to the inner program. The base curve sees inflated balances and computes swap amounts accordingly.

#### Fee reinvestment

When a fee instruction wraps around concentration in the canonical ordering, the retained fee grows the maker's real balances after settlement. On the next swap, the liquidity computation is called again with these larger real balances. A larger `x` or `y` increases `β` and the discriminant, yielding a larger `L`, which yields larger virtual reserves and deeper effective liquidity. This feedback loop is entirely automatic — no explicit reinvestment step, storage update, or additional instruction is required.

#### Invariant compliance

1. **Exact In/Out Symmetry.** The transformation computes the same virtual reserves regardless of swap direction. Token ordering is handled explicitly via `isTokenInLt`, and the virtual reserve additions are symmetric with respect to which token is input. The inner base curve provides directional symmetry over the adjusted balances.
2. **Swap Additivity.** The concentrated pool is still a constant product curve (operating on virtual reserves), so it inherits subadditivity from the curve's convexity. Splitting a trade yields less total output. Between sub-swaps within a single transaction, `L` does not change (real balances haven't been settled yet), so the splitter gains no advantage from `L` recomputation.
3. **Quote/Swap Consistency.** The instruction performs pure computation over registers and delegates via `runLoop()`. No storage reads or state-dependent operations diverge between `quote()` and `swap()`.
4. **Price Monotonicity.** Inherited from the inner constant-product curve operating on virtual reserves. The effective price function `Δy / Δx = y_v / (x_v + Δx)` is decreasing in `Δx`.
5. **Rounding Favors Maker.** Virtual reserve addition uses ceil division for the input side and floor division for the output side. Combined with the inner curve's rounding (floor for `amountOut`, ceil for `amountIn`), the maker is never disadvantaged.
6. **Balance Sufficiency.** The inner curve guarantees `amountOut < y_v = y + L · sqrt(P_min)`. Since `amountOut` is bounded by the virtual balance and includes the virtual component, settlement against real balances is enforced at the VM level.
7. **Strategy Liveness.** When one real balance is zero, the quadratic formula still yields a valid `L` (the `x · y` term vanishes, leaving `L = β / α`). Virtual reserves ensure the pool can accept swaps in the direction that restores the depleted reserve.

#### Composability

As a wrapping transformation, `_xycConcentrateGrowLiquidity2D` modifies balance registers and delegates to `runLoop()`. The inner program — typically a constant-product base curve — sees inflated balances and is agnostic to the concentration logic. Any base curve that reads balance and amount registers works correctly with the inflated values. In the canonical ordering, fees can wrap around concentration (outer position) or be wrapped by it (inner position). The precondition guard (`amountIn == 0 || amountOut == 0`) ensures concentration runs before any swap amounts are computed.

---

### Appendix A.3 — Pegged swap (sqrt-linear curve)

The pegged swap curve is designed for asset pairs whose prices stay near a 1:1 peg, such as stablecoin pairs (USDC/USDT), wrapped tokens (WETH/stETH), or cross-chain bridge tokens (WBTC/cbBTC). It provides minimal slippage near the peg while maintaining smooth price protection at extreme reserve ratios. Unlike constant product, this curve has finite reserves — one reserve can be fully depleted — making it unsuitable for volatile or uncorrelated pairs. The curve admits an analytical solution (no iterative solving), keeping gas costs predictable.

#### Invariant

The curve is defined by the invariant:

$$\sqrt{\frac{x}{X_0}} + \sqrt{\frac{y}{Y_0}} + A \cdot \left(\frac{x}{X_0} + \frac{y}{Y_0}\right) = 1 + A$$

where $x$ and $y$ are the current reserves (`balanceIn`, `balanceOut`), $X_0$ and $Y_0$ are the initial reserves (normalization factors), and $A \in [0, 2]$ is the linear width parameter. Introducing normalized variables $u = x/X_0$ and $v = y/Y_0$, and denoting the invariant constant $C = 1 + A$ (its value at the initial state $u = v = 1$), the invariant simplifies to:

$$\sqrt{u} + \sqrt{v} + A \cdot (u + v) = C$$

The parameter $A$ controls how flat the curve is near the 1:1 price. When $A = 0$, the curve reduces to a pure square root: $\sqrt{u} + \sqrt{v} = 1$. Larger values of $A$ add a linear component that flattens the curve near the peg, reducing slippage for small trades. Typical values are $A \approx 0.8\text{–}1.5$ for tightly pegged pairs and $A \approx 0.3\text{–}0.6$ for looser pegs.

#### Analytical solver

Given $u$ (the post-swap normalized input reserve), the solver computes $v$ (the post-swap normalized output reserve) by rearranging the invariant:

$$\sqrt{v} + A \cdot v = C - \sqrt{u} - A \cdot u =: R$$

Substituting $w = \sqrt{v}$ yields a quadratic in $w$:

$$A \cdot w^2 + w - R = 0$$

The standard quadratic formula $w = \dfrac{-1 + \sqrt{1 + 4AR}}{2A}$ suffers from **catastrophic cancellation** when $A$ is small. The implementation uses the numerically stable **rationalized form**:

$$w = \frac{2R}{1 + \sqrt{1 + 4AR}}$$

and then $v = w^2$. When $A = 0$, the equation reduces to $w = R$, so $v = R^2$.

> **Auditor note:** the rationalized form $\dfrac{2R}{1 + \sqrt{1 + 4AR}}$ is mathematically equivalent to the textbook $\dfrac{-1 + \sqrt{1 + 4AR}}{2A}$ but avoids subtracting two nearly-equal floating-point quantities when $A$ is small. A scanner that pattern-matches the implementation against the textbook quadratic formula will flag this as "wrong" — this is a deliberate numerical-stability choice, not a bug.

The same `solve()` function is used in both directions: exactIn computes `v` from `u`, and exactOut computes `u` from `v`, ensuring both directions solve the identical invariant equation.

#### Rate multipliers

Tokens with different decimal precisions (e.g., USDC with 6 decimals vs DAI with 18) require normalization before the curve formula can be applied. The instruction takes two rate multipliers, `rateLt` and `rateGt`, assigned by token address ordering. Each balance is multiplied by its corresponding rate to scale it to a common precision. For example, for a USDC/DAI pair where USDC has the lower address: `rateLt = 10¹²`, `rateGt = 1`, so both balances are effectively scaled to 18 decimals before the invariant is evaluated.

#### Rounding

The solver rounds in the maker's favor through a chain of directed rounding operations:

- **ExactIn**: The normalized input `u₁` is computed with floor division (larger `u₁` means more input consumed from the maker's perspective). The solver computes `v₁`, then `y₁ = ceil(v₁ · Y₀)` (ceil — the post-swap output reserve is rounded up, leaving less output for the taker). Finally, `amountOut = floor((y₀ − y₁) / rateOut)` (floor — taker receives less).
- **ExactOut**: The normalized output `v₁` is computed with floor division. The solver computes `u₁`, then `x₁ = ceil(u₁ · X₀)` (ceil — the post-swap input reserve is rounded up). Finally, `amountIn = ceil((x₁ − x₀) / rateIn)` (ceil — taker pays more).

The `solve()` function itself uses ceiling square root for the discriminant, ensuring the solved reserve is slightly larger, which propagates correctly through the rounding chain.

#### Invariant compliance

1. **Exact In/Out Symmetry.** Both directions solve the same invariant equation using the same `solve()` function — exactIn computes `v` from `u`, exactOut computes `u` from `v`. Given `exactIn(Δx) → Δy`, substituting `Δy` into the exactOut path recovers `Δx` within rounding tolerance.
2. **Swap Additivity.** The sqrt component introduces concavity analogous to the constant product curve. Splitting a trade into parts yields less total output than a single trade, because each partial trade shifts the reserves and worsens the price for subsequent parts. The curve is subadditive.
3. **Quote/Swap Consistency.** The instruction is a pure function over registers — it reads balances and amounts, computes via the analytical solver, and writes back. No storage reads or state-dependent operations, so `quote()` and `swap()` produce identical results.
4. **Price Monotonicity.** The marginal price decreases with trade size due to the concave shape of the curve. Both the sqrt and linear components contribute to this: as `u` increases, the remaining "budget" `R = C − sqrt(u) − A · u` decreases, yielding a smaller `v` per unit of additional `u`.
5. **Rounding Favors Maker.** As described above: directed rounding at every step ensures the taker receives at most (exactIn) or pays at least (exactOut) the theoretical amount.
6. **Balance Sufficiency.** The curve has finite reserves: when one reserve approaches zero (`v → 0`), `u` reaches its maximum feasible value. If the requested trade exceeds this bound, the solver reverts because `R < 0` (the invariant equation has no solution). This prevents impossible trades.
7. **Strategy Liveness.** At least one balance must be non-zero. When one reserve is fully depleted, the reverse-direction swap can restore it — the solver produces a valid solution for the direction that adds to the depleted reserve.

#### Composability

The pegged swap instruction is a single-pass **base curve** with the same composability properties as constant product: it reads balance and amount registers, computes the counterpart amount via the analytical solver, and writes it back. It makes no `runLoop()` call and has no side effects beyond register writes. The rate multiplier logic is self-contained within the instruction, so wrapping transformations and fees interact with it through the standard register interface. The recompute guard (`amountOut == 0` for exactIn, `amountIn == 0` for exactOut) prevents double-invocation within the same program.

---

### Appendix A.4 — Time-decaying virtual reserves

The decay instruction provides MEV protection by making immediate reverse swaps economically unfavorable. After each swap, the instruction penalizes the opposite-direction balance by the swap amount, and this penalty decays linearly to zero over a configurable period. This mechanism is inspired by Mooniswap's virtual balance approach [10]: a sandwich attacker who front-runs a trade and immediately reverses it faces an inflated input balance and a reduced output balance, significantly reducing the profitability of the attack.

#### Mechanism

The instruction maintains a per-token, per-direction **decaying offset** stored as a pair $(\textit{offset}, \textit{timestamp})$. The effective offset at any time $t$ is:

$$\textit{offset}_{\text{eff}}(t) = \textit{offset} \cdot \frac{\max(0,\, t_{\exp} - t)}{T}$$

where $t_{\exp} = \textit{timestamp} + T$ is the expiration time and $T$ is the configurable decay period. The offset decays linearly from its full value to zero over $T$ seconds. Once expired ($t \geq t_{\exp}$), the effective offset is zero and the balances are unmodified.

#### Execution flow

The instruction executes as a wrapping transformation:

1. **Adjust balances.** Read the current decayed offsets and apply them to the balance registers:
   - `balanceIn += offset_eff(tokenIn, buy)` (inflated — makes input appear larger, worsening the price for the taker)
   - `balanceOut −= offset_eff(tokenOut, sell)` (reduced — less output available)
2. **Delegate.** Call `runLoop()` to execute the inner program (fees and base curve) on the adjusted balances. The inner program returns the computed `(amountIn, amountOut)`.
3. **Update offsets (swap mode only).** Add the swap amounts as new offsets in the **reverse** directions:
   - `offset(tokenIn, sell) += amountIn`
   - `offset(tokenOut, buy) += amountOut`

   In quote mode (`isStaticContext = true`), this step is **skipped** — offsets are read but never written.

The offset storage is keyed by `(orderHash, token, direction)`, so each strategy maintains independent decay state per token-pair direction.

#### MEV protection intuition

Consider a sandwich attack: an attacker front-runs a victim's swap with a large buy, then back-runs with a sell. After the front-run buy, the decay instruction records the buy's `amountOut` as a sell-direction offset on the output token. When the attacker immediately attempts the reverse sell, this offset reduces `balanceOut` (from the attacker's perspective), worsening the price. The closer in time the reverse swap occurs, the larger the penalty. Over the decay period `T`, the penalty linearly diminishes, and normal trading resumes unaffected.

#### Quote/swap divergence

> **Auditor note (deliberate):** Unlike all other instructions covered in this appendix, the decay instruction has a **deliberate** divergence between `quote()` and `swap()`. In quote mode, offsets are read but not updated (step 3 is skipped). This means a `quote()` result reflects the current decay state but does not predict the decay state that a subsequent `swap()` would create. The numerical output of `quote()` for a single swap is still accurate — the divergence only matters when reasoning about sequences of swaps, since a `swap()` updates the decay state for subsequent calls.

#### Invariant compliance

1. **Exact In/Out Symmetry.** The decay offsets are stored per-direction: buying and selling a token have independent offsets. The balance adjustments are symmetric — inflating input and reducing output — regardless of the `isExactIn` flag. The inner base curve provides directional symmetry over the adjusted balances.
2. **Swap Additivity.** The decay mechanism is intentionally **superadditive for rapid successive swaps in opposite directions** (this is the MEV protection mechanism). For same-direction swaps, the instruction adds to the reverse-direction offset after each swap, making subsequent same-direction swaps see a progressively larger input balance — which is subadditive (worse prices for the splitter). The superadditivity is confined to the attack scenario it is designed to penalize.
3. **Quote/Swap Consistency.** For a single swap, `quote()` and `swap()` read the same offsets and compute the same balance adjustments, producing identical amounts. The divergence (offset update) only affects subsequent calls, not the current one.
4. **Price Monotonicity.** Inherited from the inner base curve operating on adjusted balances. The balance adjustments shift the curve but do not change its shape.
5. **Rounding Favors Maker.** The decay instruction performs only integer addition and subtraction on balances. All rounding is handled by the inner base curve.
6. **Balance Sufficiency.** The output-side offset subtraction could theoretically reduce `balanceOut` below the required `amountOut`. In practice, the decay is bounded by recent swap amounts and decays over time, so this only occurs when the pool is under active attack — in which case the revert is the desired protective behavior.
7. **Strategy Liveness.** The decay offsets expire after period `T`, so a temporarily penalized pool always recovers to its unmodified balance state. Even during active decay, the reverse-direction swap faces no penalty (its offset is independent), preserving the ability to restore depleted reserves.

#### Composability

As a wrapping transformation, the decay instruction modifies balance registers, delegates to `runLoop()`, and updates state after the inner program completes. It is agnostic to the inner program — any combination of fees and base curves works correctly with the adjusted balances. In the canonical ordering, decay typically appears between the protocol fee and concentration (or directly before the base curve if concentration is not used). The precondition guard (`amountIn == 0 || amountOut == 0`) ensures it runs before any swap amounts are computed. Because it writes to storage (offset updates), it is the only instruction in this appendix that has side effects beyond register manipulation.

---

## Appendix B — Fee mathematics

This appendix details the mathematical foundations of SwapVM's fee instructions: how fees are computed, applied, and composed through the wrapping pattern.

### Appendix B.1 — Flat fee

The flat fee instruction (`_flatFeeAmountInXD`) deducts a fixed percentage from the input amount. The fee rate is specified in basis points where `BPS = 10⁹` represents 100%. All fee instructions are wrapping instructions that delegate via `runLoop()`.

#### ExactIn

The taker specifies a fixed `amountIn`. The fee is deducted **before** the inner program executes:

$$\textit{fee} = \left\lceil \frac{\texttt{amountIn} \cdot \texttt{feeBps}}{\texttt{BPS}} \right\rceil$$

The instruction saves the original `amountIn`, reduces it by the fee (`amountIn −= fee`), calls `runLoop()` so the inner program computes `amountOut` from the reduced input, and then restores the original `amountIn`. The taker sees the full input amount; the fee is implicitly retained by the maker as the difference between what the taker paid and what the curve consumed.

#### ExactOut

The taker specifies a fixed `amountOut`. The fee is added **after** the inner program executes:

$$\textit{fee} = \left\lceil \frac{\texttt{amountIn} \cdot \texttt{feeBps}}{\texttt{BPS} - \texttt{feeBps}} \right\rceil$$

The instruction calls `runLoop()` first — the inner program computes the base `amountIn` required for the desired output. Then the fee is added: `amountIn += fee`. The denominator $\texttt{BPS} - \texttt{feeBps}$ ensures the fee is computed on the pre-fee amount (i.e., the fee is "grossed up" so the maker retains the same effective rate regardless of direction).

> **Auditor note:** $\texttt{BPS} - \texttt{feeBps} = 0$ when $\texttt{feeBps} = \texttt{BPS}$ (100% fee), causing division by zero and revert. This is a known configuration error, not a bug — see [`AquaVM_Auditor_Brief.md`](AquaVM_Auditor_Brief.md) §3.3.

#### Rounding

Both directions use ceiling division (`Math.ceilDiv`), so the fee always rounds up in favor of the maker. The taker pays at least the theoretical fee amount.

---

### Appendix B.2 — Protocol fee (static and dynamic variants)

Protocol fee instructions share the same core math via the internal `_feeAmountIn()` function but add a token transfer step: the computed fee is sent to a designated recipient address.

#### Formula

The fee computation follows the same structure as the flat fee but uses **floor** division:

- **ExactIn**: $\textit{fee} = \left\lfloor \dfrac{\texttt{amountIn} \cdot \texttt{feeBps}}{\texttt{BPS}} \right\rfloor$
- **ExactOut**: $\textit{fee} = \left\lfloor \dfrac{\texttt{amountIn} \cdot \texttt{feeBps}}{\texttt{BPS} - \texttt{feeBps}} \right\rfloor$

Floor division means the protocol fee rounds **down** — the recipient receives at most the theoretical fee. This is the opposite convention from the flat fee (which rounds up for the maker). The distinction is intentional: flat fees are retained by the maker and should round in the maker's favor; protocol fees are extracted from the maker and should round in the maker's favor by rounding down.

#### Variants

Four protocol fee instructions exist, differing only in how the fee rate is determined and how the fee is transferred:

- `_protocolFeeAmountInXD`: static fee rate and recipient from bytecode args; transfers via `safeTransferFrom`
- `_aquaProtocolFeeAmountInXD`: same as above but transfers via Aqua's `pull()` function and increments `amountNetPulled`
- `_dynamicProtocolFeeAmountInXD`: fee rate and recipient queried from an external contract via `staticcall`; transfers via `safeTransferFrom`
- `_aquaDynamicProtocolFeeAmountInXD`: dynamic fee queried externally; transfers via Aqua's `pull()`

The dynamic variants enable governance-controlled or market-adaptive fee models: an external fee provider contract can return different rates based on the order hash, maker, taker, token pair, or swap direction.

#### Quote/swap divergence

> **Auditor note (deliberate):** In quote mode (`isStaticContext = true`), the fee amount is computed identically but the token transfer is **skipped**. This means `quote()` may succeed where `swap()` reverts due to insufficient maker balance or missing token approval. The numerical output is identical when the transfer would succeed.

---

### Appendix B.3 — Wrapping pattern and fee composition

#### Why wrapping is necessary

In the exactOut direction, the fee cannot be computed until the inner program has determined the base `amountIn`. If fees executed as flat sequential instructions (without nesting), the fee would need to know the swap result before the swap runs — an impossible dependency. The wrapping pattern resolves this naturally: the fee instruction delegates inward via `runLoop()`, the inner program computes the base amount, and the fee adjusts `amountIn` after the inner program returns.

#### Direction-aware execution

The same bytecode handles both swap directions. The fee instruction inspects `isExactIn` and chooses the appropriate strategy:

- **ExactIn**: deduct fee from `amountIn` → delegate → restore `amountIn`
- **ExactOut**: delegate (inner program computes `amountIn`) → add fee to `amountIn`

This eliminates any coupling between fee logic and curve logic. The fee instruction does not need to know which base curve follows it, and the base curve does not need to know whether fees are applied.

#### Nesting multiple fees

When multiple fee instructions wrap the same base curve (as in the canonical ordering), each nests via `runLoop()`. In exactIn mode, the outermost fee sees the full `amountIn`, deducts its portion, and passes the reduced amount inward. Each inner fee deducts from the progressively smaller amount. In exactOut mode, fees accumulate outward: the innermost fee adds its portion to the base `amountIn` first, then each outer fee adds to the already-increased amount.

For example, with the canonical ordering `protocolFee → flatFee → baseCurve` and a 1% protocol fee plus a 0.3% flat fee on an exactIn swap of 1000:

1. Protocol fee deducts `floor(1000 · 0.01) = 10`, passes `amountIn = 990` inward
2. Flat fee deducts `ceil(990 · 0.003) = 3`, passes `amountIn = 987` to the base curve
3. Base curve computes `amountOut` from 987
4. Flat fee restores `amountIn = 990`
5. Protocol fee restores `amountIn = 1000`

The protocol fee is cleanly isolated: its 10 tokens are extracted before any other instruction touches the amount. The flat fee's 3 tokens are retained by the maker within the pool reserves. This ordering ensures the conservation invariant from Section 5.5: `pool_balance + protocol_fee = initial_balance + total_amountIn`.
