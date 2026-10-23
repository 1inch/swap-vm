# SwapVM

SwapVM is a virtual machine for token swaps. A maker publishes an order whose `data` carries a bytecode program; a taker calls `swap` and the program prices the fill. Strategies are bytecode, not contracts: a limit order, a Dutch auction, an AMM position and a pegged pool differ only in the instructions they combine. One router runs them all and settles the result.

This document is the technical reference: order format, execution and settlement, the sell/buy alignment rule, the invariants the design relies on, the instruction set, composition rules and worked program shapes. The economic background is in the [whitepaper](whitepaper-swap-vm-1.0.pdf).

- [Model](#model)
- [Order format](#order-format)
- [Program execution](#program-execution)
- [Settlement](#settlement)
- [Taker interface](#taker-interface)
- [Maker sell and buy](#maker-sell-and-buy)
- [Design invariants](#design-invariants)
- [Instruction reference](#instruction-reference)
- [Composition rules](#composition-rules)
- [Program shapes](#program-shapes)
- [Routers and extensions](#routers-and-extensions)
- [Cancellation](#cancellation)
- [Testing](#testing)

## Model

An **order** is `{ maker, traits, data }`. `traits` packs flags, the receiver and slice offsets into `data`; `data` holds the token pair (`tokenA < tokenB` by address), optional hook payloads and the **program**. The order hash identifies the strategy and keys all of its on-chain state.

A **router** is `SwapVM` plus an opcode set. It exposes `quote`, `swap`, `hash`, `registerOrder`, the cancellation functions of its invalidators, `simulate` and owner-only `rescueFunds`.

**Authorization** is one of two modes:

- **Signature**: EIP-712 over `Order(address maker, uint256 traits, bytes data)`, verified on every fill (`ECDSA` or ERC-1271). Tokens stay in the maker's wallet; the router pulls `tokenOut` through an allowance or Permit2.
- **Aqua** (`useAquaInsteadOfSignature`): no signature; `orderHash = keccak256(abi.encode(order))`, balances are read from and settled through [1inch Aqua](https://github.com/1inch/aqua) (`safeBalances`, `pull`, `push`). Custom receiver, WETH unwrapping and maker Permit2 are not available.

**Balances** come from one of three sources, and a program uses exactly one per path:

| Source  | Instruction       | State                           | Typical use                        |
|---------|-------------------|---------------------------------|------------------------------------|
| Static  | `StaticBalances`  | none, fixed rate                | limit orders, auctions, RFQ        |
| Dynamic | `DynamicBalances` | router storage per `orderHash`  | isolated AMM positions             |
| Aqua    | none              | the maker's Aqua position       | shared liquidity across strategies |

## Order format

### Maker traits and data

`MakerTraitsLib.build(Args)` packs the order. `traits` holds the receiver in the low 160 bits, four `uint16` end offsets of the hook slices in `data` above it, and the flags in the top bits. `data` is `tokenA ‖ tokenB ‖ [target][data] × 4 hooks ‖ program`.

| Field | Meaning |
|---|---|
| `maker` | Liquidity owner; signer or Aqua account. |
| `receiver` | Receives `tokenIn`; `address(0)` means the maker. Must be the maker for Aqua orders. |
| `tokenA`, `tokenB` | The pair, `tokenA < tokenB`; `build` reverts otherwise. |
| `shouldUnwrapWeth` | Unwrap incoming WETH to ETH for the receiver. Not with Aqua. |
| `useAquaInsteadOfSignature` | Aqua mode (see above). |
| `allowZeroAmountIn` | Permit fills with `amountIn == 0`; otherwise the VM requires `amountIn > 0`. |
| `usePermit2` | Pull the maker's `tokenOut` and `tokenOut`-side protocol fees through Permit2. Not with Aqua. |
| `has{Pre,Post}Transfer{In,Out}Hook`, `*Target`, `*Data` | `IMakerHooks` calls around each transfer; the target defaults to the maker. `build` requires the flag when a target or data is given. |
| `program` | VM bytecode. |

### Order hash

Signature orders: `_hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, maker, traits, keccak256(data))))`. Aqua orders: `keccak256(abi.encode(order))`. `router.hash(order)` returns the right one; invalidators, dynamic balances, decay state and `announcedAt` are all keyed by it, so any change to the order is a new strategy with fresh state.

## Program execution

### Encoding

```text
[opcode: 1 byte][argsLength: 1 byte][args: argsLength bytes]    # one instruction, args <= 255 bytes
```

Opcode numbers are fixed in [`OpcodeList.sol`](../contracts/libs/OpcodeList.sol) and banked by family: control `0x00`, debug `0x10`, guards and conditional jumps `0x20`, invalidators `0x40`, curves `0x50`, fees `0x70`, balances `0x90`, rates `0xb0`; `0xd0..0xef` is unallocated and `0xf0..0xff` reserved. Every instruction is a library with `opcode`, `sizeOf()`, `build(...)`, `parse(...)` and `exec(ctx, args)`; routers wire `exec` into `_dispatch`.

### Context

`runLoop()` walks the program from `nextPC` and dispatches each instruction with its `args` and the shared `Context`:

| Field   | Contents                                                            | Access                     |
|---------|---------------------------------------------------------------------|----------------------------|
| `query` | `orderHash`, `maker`, `taker`, `tokenIn`, `tokenOut`, `isExactIn`   | read-only                  |
| `swap`  | `balanceIn`, `balanceOut`, `amountIn`, `amountOut`, `surcharge`     | registers                  |
| `fee`   | protocol fee receivers and surplus estimate, settled after the loop | written by `FeeProtocol*`  |
| `vm`    | `isStaticContext`, `nextPC`, program and taker-args pointers        | control                    |

`tokenIn` / `tokenOut` follow the taker's `isAToB`. `instructionsArgs` from the taker data is a byte stream that instructions consume in order with `ctx.tryChopTakerArgs(n)`.

### Entry and exit

On entry `balanceIn = balanceOut = 0` (signature orders) or the maker's Aqua balances for the pair (Aqua orders); the taker-fixed amount sits in `amountIn` (exact-in) or `amountOut` (exact-out), the other register and `surcharge` are zero. The program must load balances and leave the missing amount in its register.

After the loop SwapVM validates, in order: `amountIn > 0` unless `allowZeroAmountIn`; `amountOut > 0`; the taker deadline; the partial-fill rule (`amount == amountIn` for exact-in, or `amount >= amountIn` with `allowPartialFill`; mirrored for exact-out); the threshold (see [Taker interface](#taker-interface)). The VM reverts when an instruction's `args` overrun the program (`RunLoopExceedProgramLength`) or an opcode is outside the router's set (`UnknownOpcode`). It does not validate jump targets, instruction order, flag alignment or economic sense.

### Wrapping instructions

Instructions that call `ctx.runLoop()` execute the rest of the program as a subtree: their pre-step runs in program order, their post-step in reverse order once the subtree returns. Wrappers: `DynamicBalances`, `Decay`, `FeeFlatIn`, `FeeFlatOut`, `FeeProtocol`, `FeeProtocolSurplus`, `InvalidateBit`, `InvalidateTokenIn`, `InvalidateTokenOut`, `RequireMinRate`.

```text
FeeProtocol(in)   pre : amountIn -= protocolFee
 DynamicBalances  pre : load reserves
  FeeFlatIn       pre : amountIn -= lpFee
   XYCSwap            : amountOut = f(amountIn)
  FeeFlatIn       post: amountIn += lpFee
 DynamicBalances  post: reserves += amountIn, -= amountOut; persist (swap only)
FeeProtocol       post: amountIn += protocolFee; receivers are paid at settlement
```

The LP fee is reinvested into the reserves, the protocol fee is not. Swapping `FeeProtocol` and `DynamicBalances` would record in the reserves a fee that leaves to the receivers. Read a program as nested execution, not as a feature list, and use each stateful wrapper once per reachable path.

### Quote vs swap

`quote()` runs the identical program with `isStaticContext = true`: stateful instructions read but do not write, Aqua balances are read live. Call `router.asView().quote(...)` to force a static call. Given the same chain state and inputs, `quote` returns exactly what `swap` executes. A quote is still a snapshot: balances, fills, time, base fee, oracles and Aqua liquidity can move before the swap, and signatures, allowances, hooks and callbacks are not exercised. Relative timestamps of an unregistered order resolve to "now" in quotes and are pinned by the first swap. Use the same order and taker data for both calls and protect the swap with a threshold and a deadline.

### Conventions

- `tokenA < tokenB` by address; `direction = true` is A to B. `LimitSwap.build(tokenIn, tokenOut)` and `JumpIfDirection.build(tokenIn, tokenOut, pc)` derive it.
- `isExactIn` is the taker's choice of which amount to fix. Sell / buy is the maker's choice of which balance is fixed; the two are independent (see [Maker sell and buy](#maker-sell-and-buy)).
- Units: percentages use `BPS = 1e7` (`0.003e7` is 0.3%); `PiecewiseLinearSurcharge` scales are Q24 (`1 << 23` is +50%); `XYCConcentrateSwap` bounds are square roots of the price in `tokenB` per `tokenA`, scaled by `1e18`; `DutchAuction.decay` and `OnlyTakerTokenSupplyShareGte.share` are `1e18` fractions.
- Timestamps are `uint40`. With `Time.RELATIVE_TIME_FLAG` (`1 << 39`) set, `Deadline`, `DutchAuction`, `PiecewiseLinearSurcharge` and `WhitelistSequential` count from the order's announcement: `registerOrder`, or the first swap if never registered.
- Rounding favors the maker everywhere: `amountIn` rounds up, `amountOut` rounds down, balance scaling rounds the maker's income up and the maker's spending down.

## Settlement

`swap` prices first and moves tokens afterwards; no instruction transfers tokens.

```text
swap(order, amount, takerTraitsAndData)
  orderHash = hash(order); lock(orderHash)
  tokenIn / tokenOut from isAToB
  Aqua: (balanceIn, balanceOut) = AQUA.safeBalances(...)   |   signature: verify
  (amountIn, amountOut) = runLoop()
  maker and taker validation
  transferOut                                               # maker -> taker, default first
    preTransferOut hook -> preTransferOutCallback
    tokenOut-side protocol fees: maker -> receivers
    tokenOut: maker -> `to` (Aqua pull or transferFrom / Permit2; unwrap WETH if taker asks)
    postTransferOut hook (receives the fee amount)
  transferIn                                                # taker -> maker
    preTransferIn hook -> preTransferInCallback
    tokenIn-side protocol fees: taker -> receivers
    tokenIn: taker -> receiver (transferFrom / Permit2, or wrapped msg.value; unwrap WETH if maker asks)
    postTransferIn hook (receives the fee amount)
  unlock; emit Swapped
```

- **Order of transfers.** `tokenOut` moves first by default, so `ITakerCallbacks.preTransferInCallback` can source `tokenIn` flash-swap style. `isFirstTransferFromTaker` swaps the two blocks.
- **Hooks and callbacks.** `IMakerHooks.{pre,post}Transfer{In,Out}` run on the maker or on the target encoded in `order.data`, with the maker's data and the taker's per-hook data. `ITakerCallbacks.preTransfer{In,Out}Callback` run on the taker.
- **Native ETH.** `msg.value` is accepted only when `tokenIn` is WETH: the router wraps `amountIn` and refunds the excess. With Aqua orders this needs `useTransferFromAndAquaPush`.
- **Aqua.** By default the taker must have pushed `tokenIn` into the maker's position for this `orderHash` (for example in `preTransferInCallback`); the router checks the raw balance grew by `amountIn` and pulls `tokenIn`-side fees from the position. With `useTransferFromAndAquaPush` the router pulls from the taker, pays the fees and pushes the net amount.
- **Permit2.** Maker `usePermit2` covers `tokenOut` and `tokenOut`-side fees, taker `usePermit2` covers `tokenIn` and `tokenIn`-side fees. Both use an existing Permit2 allowance (token approved to Permit2, router authorized as spender); no Permit2 signature is submitted. Routers also inherit `PermitAndCall` to bundle a token permit with the call.
- **Protocol fees.** `FeeProtocol` leaves receivers and a total in `ctx.fee`; settlement pays each receiver its share of the flat fee plus `surplusBps` of the maker's gain over the `FeeProtocolSurplus` estimate. Dust from the split stays with the maker.
- **Reentrancy.** A transient lock per `orderHash` guards `swap`; callbacks may fill other orders.

## Taker interface

`TakerTraitsLib.build(Args)` packs a 22-byte header (ten `uint16` slice offsets and 16 flag bits) followed by the optional slices.

| Field | Meaning |
|---|---|
| `isExactIn` | `amount` is the input (`true`) or the output (`false`). |
| `isAToB` | Pay `tokenA`, receive `tokenB`; `false` reverses. |
| `allowPartialFill` | Accept `amountIn <= amount` (exact-in) or `amountOut <= amount` (exact-out). Without it the program must consume `amount` exactly. |
| `threshold` | 32 bytes or empty. Minimum `amountOut` (exact-in) or maximum `amountIn` (exact-out). On a partial fill it scales pro rata: `threshold * amountIn / amount` rounded up, or `threshold * amountOut / amount` rounded down. |
| `isStrictThresholdAmount` | Require equality with the threshold instead of min / max. |
| `deadline` | `uint40`; `0` disables. |
| `to` | Receives `tokenOut`; `address(0)` means the taker. |
| `shouldUnwrapWeth` | Unwrap received WETH to `to`. |
| `isFirstTransferFromTaker` | Pay before receiving. |
| `usePermit2` | Pull `tokenIn` through Permit2. |
| `useTransferFromAndAquaPush` | Aqua orders: pay via `transferFrom` and let the router push. |
| `hasPreTransfer{In,Out}Callback`, `preTransfer{In,Out}CallbackData` | `ITakerCallbacks` on the taker. |
| `{pre,post}Transfer{In,Out}HookData` | Taker data passed to the maker's hooks. |
| `instructionsArgs` | Byte stream for instructions (`ctx.tryChopTakerArgs`). |
| `signature` | Maker signature; empty for Aqua orders. |

```solidity
bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
    taker: address(this),
    isExactIn: true,
    isAToB: true,
    allowPartialFill: false,
    usePermit2: false,
    shouldUnwrapWeth: false,
    isStrictThresholdAmount: false,
    isFirstTransferFromTaker: false,
    useTransferFromAndAquaPush: false,
    threshold: abi.encodePacked(minOut),
    to: address(0),
    deadline: uint40(block.timestamp + 5 minutes),
    hasPreTransferInCallback: false, hasPreTransferOutCallback: false,
    preTransferInHookData: "",  postTransferInHookData: "",
    preTransferOutHookData: "", postTransferOutHookData: "",
    preTransferInCallbackData: "", preTransferOutCallbackData: "",
    instructionsArgs: "",
    signature: signature
}));

(uint256 quotedIn, uint256 quotedOut,) = router.asView().quote(order, 1000e6, takerData);
(uint256 amountIn, uint256 amountOut,)  = router.swap(order, 1000e6, takerData);
```

Reuse the same `takerData` for `quote` and `swap`; send ETH with `swap` when `tokenIn` is WETH.

## Maker sell and buy

The taker fixes one amount per fill (`isExactIn`). The maker fixes one balance per order: a **sell** order disposes of a fixed `balanceOut` and lets the price float on the input side, a **buy** order acquires a fixed `balanceIn` and lets the price float on the output side. The two choices are independent: a sell order serves exact-in and exact-out fills alike.

Every side-sensitive instruction carries a flag, and all flags of one program must point the same way. The fixed side is the order's unit of account; everything that varies is expressed on the floating side.

| | Sell: fixed `balanceOut` | Buy: fixed `balanceIn` |
|---|---|---|
| Fill cap | `InvalidateTokenOut` | `InvalidateTokenIn` |
| `adjustIn` (`DutchAuction`, `PiecewiseLinearSurcharge`, `OraclePriceAdjuster`, `BaseFeeAdjuster`, `FillGridAdjuster`) | `true`: the surcharge raises `balanceIn` | `false`: the surcharge lowers `balanceOut` |
| `isTokenIn` (`FeeProtocol`, `FeeProtocolSurplus`) | `true`: fees in `tokenIn`; estimate is the expected receive | `false`: fees in `tokenOut`; estimate is the expected spend |
| `BaseFeeAdjuster.ethPrice` | ETH priced in `tokenIn` | ETH priced in `tokenOut` |
| `OraclePriceAdjuster.marketValue` | `tokenIn` value of `balanceOut` | `tokenOut` value of `balanceIn` |
| Unit of `surcharge` | `tokenIn` | `tokenOut` |

### Why the rule holds

1. **The cap must be a constant of the order.** `InvalidateTokenOut` reads `balanceOut` when it executes, subtracts the recorded fills, scales `balanceIn` (rounded up) and `surcharge` (rounded down) to the remaining share, runs the subtree and records `amountOut`. The cap, the fills and the scaling ratio are meaningful only if `balanceOut` is the same number on every fill. An adjuster that moves `balanceOut` in the same program makes the cap drift with time, gas price or the oracle: the remaining capacity reported to later fills is wrong and the maker's total delivery depends on when fills happen. `InvalidateTokenIn` is the mirror image.
2. **`surcharge` is one currency.** Auctions, `FillGridAdjuster` and a favorable `OraclePriceAdjuster` move add to `surcharge` in units of the balance they moved; `BaseFeeAdjuster` and an adverse oracle move subtract from it in the same units and are capped by it, which is exactly the statement "never below the limit price". Mixed `adjustIn` flags add `tokenIn` and `tokenOut` amounts into one register.
3. **Fees and estimates are measured on the floating side.** With `isTokenIn = true` the curve prices the net input, the taker pays net plus fee and the maker's `tokenOut` is untouched; with `isTokenIn = false` the curve prices the gross output, the maker pays gross and the taker receives gross minus fee. `FeeProtocolSurplus` scales its estimate by the filled share of the fixed side (`amountOut / balanceOut` when `isTokenIn`, `amountIn / balanceIn` otherwise) and settlement measures the surplus on the floating side. Pointing `isTokenIn` at the fixed side spends the fixed quantity on fees and takes the share on a balance that includes the surcharge, so the estimate and the surplus fee are wrong.
4. **Adjuster parameters are floating-side numbers.** `ethPrice` and `marketValue` are denominated in the floating token. Flipping `adjustIn` without re-expressing them misprices the order.

### Position relative to the invalidator

| Instruction | Position | Reason |
|---|---|---|
| `DutchAuction`, `PiecewiseLinearSurcharge` | before | Surcharge on the whole order; the invalidator scales it to the remaining capacity for the adjusters that follow. |
| `OraclePriceAdjuster` | after the surcharge, before the invalidator | `marketValue` describes the whole fixed balance, not the remainder. |
| `FeeProtocolSurplus` | before | The estimate describes the whole order and is scaled by the filled share. |
| `BaseFeeAdjuster` | before or after, deliberately | An absolute amount. Before: the refund is spread over the order and a partial fill gets its pro rata share. After: every fill gets the full refund, bounded by the remaining `surcharge`. |
| `FillGridAdjuster` | after, last before the curve | Its full-fill exit compares the amount with the final remaining balance and it needs the final `surcharge`. |
| Curve | last | Prices against the final balances. A curve before the invalidator prices against the full balance, and a fill of the remainder reverts instead of clamping. |

### A misaligned example

Sell 200 B for at least 100 A with a +50% auction that decays to the limit price.

Aligned (`PiecewiseLinearSurcharge(adjustIn = true)`, `InvalidateTokenOut`): at the start `balanceIn = 150 A`, cap 200 B. A taker buys 100 B for 75 A; `filled = 100 B`. After the auction the remaining 100 B cost 50 A. The maker sells exactly 200 B and never below 100 A.

Misaligned (`adjustIn = false` with `InvalidateTokenOut`): at the start the surcharge lowers `balanceOut` to 133.3 B and the invalidator caches that as the cap. A taker "fills everything" and receives 133.3 B for 100 A; `filled = 133.3 B`. The order is not done: once the auction ends `balanceOut` is 200 B again and 66.7 B remain for 33.3 A. The fixed quantity became a time-dependent capacity, `LimitSwapFullAmount` would have treated 133.3 B as the full amount, and a `BaseFeeAdjuster(adjustIn = true)` in the same program would subtract A from a surcharge held in B.

## Design invariants

### Enforced by the VM and settlement

These hold for every program on every router.

- **Pricing and settlement are separate.** Instructions read and write the `Context`; tokens move after the loop by the amounts left in the registers. No instruction transfers tokens; an `Extruction` target is an external call that can act only on what it controls.
- **A fill always moves value.** `amountOut > 0`, and `amountIn > 0` unless the maker set `allowZeroAmountIn`.
- **Taker limits hold.** Threshold (scaled pro rata on partial fills), partial-fill rule and deadline are checked after the loop, before any transfer.
- **Quote equals swap.** The same bytecode runs in both; stateful instructions write only when `isStaticContext` is false.
- **Rounding favors the maker.** Every instruction rounds `amountIn` up and `amountOut` down; balance scaling rounds the maker's income up and the maker's spending down.
- **Authorization on every fill.** A signature (EOA or ERC-1271) or Aqua balances; the maker can always stop fills by revoking the allowance or withdrawing from Aqua.
- **One fill per order at a time.** A transient lock per `orderHash`.
- **Closed opcode set.** Unknown opcodes and `args` past the end of the program revert.

### Expected from every program

The economic properties the design is built around. [`CoreInvariants`](../test/solidity/invariants/CoreInvariants.t.sol) asserts them; defaults in the last column.

| Invariant | Statement | Check |
|---|---|---|
| Symmetry | `exactIn(X) = Y` implies `exactOut(Y) ≈ X` | quotes, 2 wei |
| Quote/swap consistency | `quote` and `swap` return identical amounts from the same state | exact |
| Monotonicity | `amountOut / amountIn` does not improve as the trade grows | quotes, 0 bps |
| Additivity | one fill of `A + B` returns at least `A` then `B` in sequence: splitting never beats a single fill | real swaps on snapshots, 0 wei |
| Rounding favors the maker | 1 to 1000 wei trades never beat the one-token rate (exact-in) or cost less than it (exact-out) | 1% |
| Balance sufficiency | an amount above `balanceOut` reverts or clamps, never over-delivers | quote of `1e6` tokens |
| Liveness | a depleted side is refilled by trading the other way; stateful positions do not dead-lock | per-shape tests |

[`RoundingInvariants`](../test/solidity/invariants/RoundingInvariants.sol) adds two attack-shaped checks: many dust swaps never return more than one large swap, and `A → B → A` round trips never end above the start.

Some instruments price fills differently on purpose and fail a check by design: `BaseFeeAdjuster` after the invalidator (an absolute refund per fill) breaks monotonicity and additivity, `FillGridAdjuster` (a premium on partial fills, so a larger fill gets a better unit price) breaks monotonicity, and `Decay` is path dependent and skips additivity. Fixed-rate programs satisfy monotonicity and additivity with equality. Any other skip (`config.skipAdditivity`, `skipMonotonicity`, `skipSymmetry`, `skipSpotPrice`) needs an economic reason and replacement tests.

### Not guaranteed

- A program that runs is not a program that is safe. The VM does not check jump targets, instruction order, flag alignment or parameter sanity; production integrations should admit only reviewed shapes with bounded parameters, and every reachable branch, including `Extruction` targets, needs the same review.
- A quote is a snapshot of chain state; see [Quote vs swap](#quote-vs-swap).
- Aqua liquidity is shared by all strategies of the maker, so `balanceIn` / `balanceOut` can change between quote and swap through other orders.
- Hooks, callbacks, `Extruction` targets and `IProtocolFeeProvider` contracts are external code chosen by the maker or taker.
- Protocol-fee dust from splitting across receivers stays with the maker, which is super-additive by a few wei on extremely thin AMM positions with fees in `tokenOut`.

## Instruction reference

Routers: **F** [`SwapVMRouter`](../contracts/routers/SwapVMRouter.sol) (`Opcodes`), **L** [`LimitSwapVMRouter`](../contracts/routers/LimitSwapVMRouter.sol) (`LimitOpcodes`), **A** [`AquaSwapVMRouter`](../contracts/routers/AquaSwapVMRouter.sol) (`AquaOpcodes`). An opcode outside the router's set reverts with `UnknownOpcode`. **L** has no AMM curves, dynamic balances or LP fees; **A** has no static balances, limit curves, invalidators or auction adjusters, but does accept `DynamicBalances`. `*Debug` routers add `Print*` and `PatchSwapRegisters`. "Wraps" marks instructions that call `runLoop()`.

### Control and guards

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `Stop` | F | `()` | Ends the program. |
| `Revert` | F | `(bytes4 or bytes)` | Reverts with `InstructionRevert(args)`. |
| `Salt` | F L A | `(uint64 or bytes)` | No-op; makes otherwise identical orders hash differently. |
| `Deadline` | F L A | `(uint40 ts)` | Reverts after `ts`. |
| `Jump` | F L A | `(uint16 pc)` | Sets `nextPC`. |
| `JumpIfDirection` | F L A | `(bool aToB, uint16 pc)` | Jumps when the swap direction matches. |
| `JumpIfTokenIn` / `JumpIfTokenOut` | F | `(address token, uint16 pc)` | Jumps when the token matches. |
| `PrivateOrder` | F L | `(address taker)` | Reverts unless the taker matches (low 80 bits compared). |
| `WhitelistCoequal` | F L | `(uint16 pc, address[] takers)` | A listed taker jumps to `pc`; others continue. |
| `WhitelistSequential` | F | `(uint40 start, uint16 pc, address[] takers, uint16[] durations)` | Reverts before `start`. Taker `k` unlocks at `start + sum(durations[0..k))` and jumps; unlisted takers revert until all durations elapse, then continue. |
| `OnlyTakerTokenBalanceNonZero` / `...Gte` | F L A | `(address token[, uint256 amount])` | Reverts unless the taker holds the token (NFT-compatible). |
| `OnlyTakerTokenSupplyShareGte` | F L A | `(address token, uint64 share)` | Reverts unless `balance / totalSupply >= share`. |
| `OnlyTxOriginTokenBalanceNonZero` | F L A | `(address token)` | Same check on `tx.origin`; weak, any contract in the transaction passes. |
| `Extruction` | F L A | `(address target, bytes args)` | Calls `IExtruction.extruction(...)` (`IStaticExtruction` in quotes), which returns new registers, `nextPC` and how many taker args to consume. |

### Invalidation

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `InvalidateBit` | F L | `(uint32 bit)` | Wraps. Maker-scoped bitmap nonce: reverts if set, sets it after the subtree (swap only). |
| `InvalidateTokenIn` | F L | `()` | Wraps. Caps cumulative `amountIn` by `balanceIn` per `(maker, orderHash, tokenIn)`; scales `balanceOut` and `surcharge` to the remaining capacity before the subtree, records the fill after. Buy orders. |
| `InvalidateTokenOut` | F L | `()` | Wraps. Same for `amountOut` / `balanceOut`. Sell orders. |
| `ValidateSeriesEpoch` | F L | `(uint32 seriesId, uint32 epoch)` | Reverts unless the maker's current epoch for `seriesId` equals `epoch`. |

### Balances

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `StaticBalances` | F L | `(uint256 balanceA, uint256 balanceB)` | Sets both balances from the order. Stateless. |
| `DynamicBalances` | F A | `(uint256 balanceA, uint256 balanceB)` | Wraps. Loads reserves stored per `(orderHash, token)`, falling back to the arguments while both are zero; stores `balanceIn + amountIn` and `balanceOut - amountOut` after the subtree (swap only). Reverts if both would reach zero. |
| `DutchAuction` | F | `(bool adjustIn, uint40 start, uint64 decay, uint24 surchargeBps)` | Exponential surcharge `(1 + s) * decay^elapsed - 1` while positive, raising `balanceIn` or lowering `balanceOut`; adds it to `surcharge`. |
| `PiecewiseLinearSurcharge` | F L | `(bool adjustIn, uint40 start, uint16[] durations, uint24[] scales)` | Linear interpolation of Q24 surcharges across `durations`; `scales[0]` before `start`, the last scale after the end. Adds to `surcharge`. |
| `Decay` | F A | `(uint16 period)` | Wraps. Remembers the last swap per direction and prices the opposite direction as if it had not happened, releasing it linearly over `period` seconds. Dampens sandwiching. |

### Curves

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `LimitSwap` | F L | `(bool direction)` | Fixed rate `balanceOut / balanceIn`, one direction; clamps to the full balances (the taker needs `allowPartialFill`). |
| `LimitSwapFullAmount` | F L | `(bool direction)` | Fill-or-kill: reverts unless the taker covers the whole balance. |
| `XYCSwap` | F A | `()` | Constant product. |
| `XYCConcentrateSwap` | F A | `(uint256 sqrtPriceMin, uint256 sqrtPriceMax)` | Constant product with liquidity concentrated in the range; retained fees are reinvested. Clamps to `balanceOut`. |
| `PeggedSwap` | F A | `(uint256 x0, uint256 y0, uint256 linearWidth, uint256 rateA, uint256 rateB)` | `sqrt(x/x0) + sqrt(y/y0) + A(x/x0 + y/y0) = 1 + A`; `rateA` / `rateB` normalize decimals, `linearWidth = A * 1e27` up to `5000e27`. Finite reserves, hard price bounds. |

### Fees

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `FeeFlatIn` | F A | `(uint24 feeBps)` | Wraps. LP fee on `amountIn`, kept by the maker; the subtree prices the net amount. |
| `FeeFlatOut` | F | `(uint24 feeBps)` | Wraps. LP fee on `amountOut`. Superadditive with reinvesting AMMs; prefer `FeeFlatIn`. |
| `FeeProtocol` | F L A | `(bool isTokenIn, ReceiverConfig[] receivers, ProviderConfig[] providers)` | Wraps. Third-party fees for up to 15 receivers: flat `feeBps` and `surplusBps` of the maker's gain over the `FeeProtocolSurplus` estimate. Providers answer through `IProtocolFeeProvider`. Transfers happen at settlement. |
| `FeeProtocolSurplus` | F L | `(bool isTokenIn, uint256 estimated)` | Wraps. The maker's expected receive (sell) or spend (buy), scaled to the filled share. Same `isTokenIn` as `FeeProtocol`. |

### Rates

| Instruction | Routers | `build(...)` | Behavior |
|---|---|---|---|
| `RequireMinRate` | F L A | `(uint64 rateA, uint64 rateB)` | Wraps. Maker-side floor on the final amounts: `amountIn * rateOut >= rateIn * amountOut`, with `(rateIn, rateOut) = (rateA, rateB)` for A to B and swapped otherwise. One instance fits one direction. |
| `OraclePriceAdjuster` | F L | `(bool adjustIn, uint160 marketValue, uint8 tokenInDecimals, uint8 tokenOutDecimals, Feed[] feeds)` | Moves the adjusted balance by the difference between `marketValue` and the value implied by one or two Chainlink feeds (staleness-checked). Moves against the maker are capped by `surcharge`. |
| `BaseFeeAdjuster` | F L | `(bool adjustIn, uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount)` | Returns `(basefee - baseGasPrice) * gasAmount * ethPrice / 1e18` of the surcharge to the taker, capped by `surcharge`. |
| `FillGridAdjuster` | F L | `(bool adjustIn, uint24[] fillBps, uint24[] adjustBps)` | Partial-fill premium: moves the floating balance against the taker by `adjustBps` of `surcharge`, interpolated over the fill grid and zero at a full fill. Last adjustment before the curve. |

## Composition rules

### One balance source per path

- `StaticBalances`: fixed rate; the program is still stateful through invalidators.
- `DynamicBalances`: router storage keyed by `orderHash`; quotes read it, swaps write it.
- Aqua (`useAquaInsteadOfSignature`): the router loads `balanceIn` / `balanceOut` from the maker's Aqua position before the first instruction, so the program has no balance instruction. Prepending `DynamicBalances` replaces the Aqua snapshot with router-local accounting.
- `Extruction` may synthesize registers; the target then owns pricing and bounds.

### Invalidation and adjusters

- Align every `adjustIn`, `isTokenIn` and the token invalidator with the order's fixed side, and keep the order auction, `OraclePriceAdjuster`, `BaseFeeAdjuster`, invalidator, `FillGridAdjuster`, curve (see [Maker sell and buy](#maker-sell-and-buy)).
- `surcharge` is the maker's price improvement over the limit price. Taker-favoring adjusters are capped by it, so the limit price always holds.
- `InvalidateBit` bits are shared by all orders of a maker; reusing a bit links them.

### Fees

- `FeeFlatIn` / `FeeFlatOut` stay with the maker. `FeeProtocol` fees leave to the receivers at settlement; keep it outside `DynamicBalances`.
- `FeeProtocolSurplus` precedes the token invalidator and uses the same `isTokenIn` as `FeeProtocol`.
- `RequireMinRate` guards the subtree after it; put it before `Extruction`. Takers still need thresholds.

### Control flow

- Jump targets are absolute byte offsets (`uint16`) that must land on instruction boundaries; compute them from `sizeOf()`. A target past the end stops execution, an unconditional backward jump loops until out of gas, a misaligned target executes garbage.
- A wrapper's subtree is whatever the loop executes until the program ends, so jumps inside a subtree are fine.
- Every reachable branch needs a balance source, a curve and the same checks as the main path.
- `Extruction` targets must be deterministic and behave identically in view and mutable mode; they may read storage in quotes but write only in swaps.

## Program shapes

The letters name the routers that run the shape. The snippets build only the program; the first one also shows the order.

### Fixed-rate limit order, partial fills (F, L)

```solidity
// USDC < WETH by address, so USDC is tokenA. Sell 0.5 WETH for 1000 USDC, fillable in parts.
bytes memory program = bytes.concat(
    Deadline.build(uint40(block.timestamp + 1 days)),
    ValidateSeriesEpoch.build(1, 0),          // seriesEpochIncrease(1) cancels every order of series 1
    StaticBalances.build(1000e6, 0.5e18),
    InvalidateTokenOut.build(),               // cumulative WETH out <= 0.5
    LimitSwap.build(USDC, WETH)
);

ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
    maker: maker,
    receiver: address(0),                     // 0 = maker
    tokenA: USDC,
    tokenB: WETH,
    shouldUnwrapWeth: false,
    useAquaInsteadOfSignature: false,
    allowZeroAmountIn: false,
    usePermit2: false,                        // true: pull maker tokenOut through Permit2
    hasPreTransferInHook: false,  hasPostTransferInHook: false,
    hasPreTransferOutHook: false, hasPostTransferOutHook: false,
    preTransferInTarget: address(0),  preTransferInData: "",
    postTransferInTarget: address(0), postTransferInData: "",
    preTransferOutTarget: address(0), preTransferOutData: "",
    postTransferOutTarget: address(0), postTransferOutData: "",
    program: program
}));

bytes32 orderHash = router.hash(order);       // EIP-712 digest, sign off-chain
```

The maker approves the router (or Permit2) for 0.5 WETH. Takers pass the signature in `takerData`.

### One-shot fill-or-kill (F, L)

```solidity
bytes memory program = bytes.concat(
    StaticBalances.build(100e18, 200e18),
    InvalidateBit.build(7),                   // nonce 7 of this maker, usable once
    LimitSwapFullAmount.build(true)
);
```

The taker's amount must cover the whole 100 / 200 pair. `LimitSwap` instead allows one partial fill.

### Dutch auction with gas compensation (F, L)

```solidity
uint16[] memory durations = new uint16[](1);
durations[0] = 5 minutes;
uint24[] memory scales = new uint24[](2);
scales[0] = 1 << 23;                          // +50% over the limit price at start
scales[1] = 0;                                // limit price after 5 minutes

bytes memory program = bytes.concat(
    StaticBalances.build(100e18, 200e18),     // sell 200 B for at least 100 A
    PiecewiseLinearSurcharge.build(true, Time.RELATIVE_TIME_FLAG, durations, scales), // starts at announcement
    BaseFeeAdjuster.build(true, 30 gwei, 3000e18, 150_000), // refund gas above 30 gwei at 1 ETH = 3000 A
    InvalidateTokenOut.build(),
    LimitSwap.build(true)
);
```

A sell order, so every flag is `true` and the cap is `InvalidateTokenOut`.

### Full static order with a whitelist branch (F, L)

Every feature is optional; the order of the ones present is fixed by the rules above.

```text
prefix: Deadline, Salt, PrivateOrder, Only*, ValidateSeriesEpoch   validation only, registers untouched
StaticBalances
WhitelistCoequal -> @whitelisted
  OnlyTakerTokenBalanceNonZero       public branch: access token
  FeeProtocol(receivers)
  Jump -> @common
@whitelisted:
  FeeProtocol(discounted receivers)
@common:
  FeeProtocolSurplus
  PiecewiseLinearSurcharge
  OraclePriceAdjuster
  BaseFeeAdjuster
  InvalidateTokenOut | InvalidateTokenIn | InvalidateBit
  FillGridAdjuster
  LimitSwap | LimitSwapFullAmount
```

Both branches end at `@common`, so each wrapper runs once whichever branch the taker takes. Forward targets are known only after the skipped section is written: build the jump with a placeholder and patch it (`WhitelistCoequal.patchNextPC`, `Jump.patchNextPC`), or compute the offsets from `sizeOf()`.

### Constant-product AMM with LP and protocol fees (F, A)

```solidity
FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
receivers[0] = FeeProtocol.ReceiverConfig({ receiver: treasury, feeBps: 0.0005e7, surplusBps: 0 }); // 0.05% of amountIn
FeeProtocol.ProviderConfig[] memory noProviders;

bytes memory program = bytes.concat(
    FeeProtocol.build(true, receivers, noProviders), // outside the reserves
    DynamicBalances.build(100_000e6, 50e18),        // initial reserves, then stored per orderHash
    FeeFlatIn.build(0.003e7),                       // 0.3% LP fee, reinvested
    XYCSwap.build()
);
```

Signature-backed: the maker keeps the tokens in its wallet and the router pulls `tokenOut` on every fill. Two-directional AMM shapes have no fixed side, so they carry no invalidator and the fee flag only selects the fee token.

### Aqua concentrated AMM with decay (F, A)

```solidity
bytes memory program = bytes.concat(
    FeeFlatIn.build(0.003e7),
    Decay.build(300),                              // the reverse price recovers over 5 minutes
    XYCConcentrateSwap.build(0.9e18, 1.1e18)       // sqrt bounds: 0.81 .. 1.21 tokenB per tokenA
);
```

Aqua supplies the reserves, so there is no balance instruction. Traits: `useAquaInsteadOfSignature = true`, `usePermit2 = false`, default receiver, no WETH unwrapping; ship the order and balances through Aqua.

### Pegged pair (F, A)

```solidity
// USDC (6 decimals) is tokenA, DAI (18 decimals) is tokenB; the rates bring both to 1e18
bytes memory program = bytes.concat(
    DynamicBalances.build(1_000_000e6, 1_000_000e18),
    FeeFlatIn.build(0.0001e7),                                     // 0.01%
    PeggedSwap.build(1_000_000e18, 1_000_000e18, 100e27, 1e12, 1)  // x0, y0 normalized; A = 100; rateA, rateB
);
```

The reserves are finite: the curve has hard price bounds and does not follow a drifting peg.

### Direction-dependent fee (F, A)

```solidity
uint16 feeAToBPC = uint16(DynamicBalances.sizeOf() + JumpIfDirection.sizeOf() + FeeFlatIn.sizeOf() + Jump.sizeOf());
uint16 curvePC = uint16(feeAToBPC + FeeFlatIn.sizeOf());

bytes memory program = bytes.concat(
    DynamicBalances.build(1_000e18, 1_000e18),
    JumpIfDirection.build(true, feeAToBPC),
    FeeFlatIn.build(0.003e7),                  // B to A: 0.3%
    Jump.build(curvePC),
    FeeFlatIn.build(0.0005e7),                 // A to B: 0.05%
    XYCSwap.build()
);
```

Each `FeeFlatIn` wraps whatever the loop executes after it, so the `Jump` inside the first subtree is fine. Test both directions in quote and swap mode.

### Best-route selection through `Extruction` (F)

```solidity
bytes memory xyc = XYCSwap.build();
bytes memory pegged = PeggedSwap.build(100e18, 100e18, 100e27, 1, 1);
bytes memory selectorArgs = abi.encodePacked(uint8(2), uint16(xyc.length), xyc, uint16(pegged.length), pegged);

bytes memory program = bytes.concat(
    DynamicBalances.build(100e18, 100e18),              // bounds the maker's spend
    Extruction.build(address(selector), selectorArgs)   // runs both curves on the same registers, keeps the better output
);
```

[`BestRouteSelector`](../test/solidity/mocks/BestRouteSelector.sol) re-enters `runLoop` on each sub-program with a fresh context and returns the registers of the best one. The target replaces pricing and must be deterministic across quote and swap; `RequireMinRate` before `Extruction` adds a maker rate floor to one-directional programs.

## Routers and extensions

| Router              | Opcode set     | Scope |
|---------------------|----------------|-------|
| `SwapVMRouter`      | `Opcodes`      | full instruction set |
| `LimitSwapVMRouter` | `LimitOpcodes` | one-directional strategies: `StaticBalances`, `LimitSwap*`, invalidators, epochs, whitelists, `PiecewiseLinearSurcharge`, the adjusters, `FeeProtocol*`, `Extruction` |
| `AquaSwapVMRouter`  | `AquaOpcodes`  | Aqua-shipped AMMs: curves, `DynamicBalances`, `Decay`, `FeeFlatIn`, `FeeProtocol`, `RequireMinRate`, guards, `Extruction` |

`*Debug` variants add the debug opcodes. Every router includes `Simulator` (`simulate`), `Rescuable` (`rescueFunds`, owner-only; the owner has no other power) and `OrderRegistrator`. A custom router is an opcode set wired into `_dispatch`:

```solidity
contract MyRouter is SwapVM, Opcodes {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "MyRouter", "1") {}

    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args); // or route to your own instruction libraries
    }
}
```

**Order registry.** `registerOrder(order, signature)` verifies the order (signature, or Aqua balances for the pair), records `announcedAt[orderHash]` once and emits `OrderRegistered` for indexers. Relative timestamps (`Time.RELATIVE_TIME_FLAG`) count from this moment; an unregistered order is pinned by its first swap.

**Native ETH sell orders.** [`NativeOrderFactory`](../contracts/extensions/nativeorder/NativeOrderFactory.sol) deploys a deterministic CREATE2 escrow that wraps `msg.value` into WETH, approves the router and becomes the maker of a signature order validated through ERC-1271. The escrow address commits to the original maker, `traits`, `keccak256(data)`, `expiration` and `maxBaseFee`; the program must sell WETH, use an explicit receiver and disable Aqua and maker Permit2. ERC-1271 rejects fills from `expiration`, so add `Deadline.build(expiration)` if quotes must expire at the same time. `cancel` returns the balance to the maker at any time; `cancelExpired` and `cancelExpiredForReward` let others do it after expiry. Cancellation does not revoke the allowance, so refunding the escrow before `expiration` makes the order fillable again.

## Cancellation

Routers with invalidators (**F**, **L**) expose maker functions: `invalidateBit(bit)`, `invalidateBits(slot, mask)`, `invalidateTokenIn(orderHash, token)` and `invalidateTokenOut(orderHash, token)` (set the fill to the maximum), `seriesEpochIncrease(seriesId)`, `seriesEpochAdvance(seriesId, n)`. A signed order without an invalidator, `ValidateSeriesEpoch` or `Deadline` can only be stopped by revoking the router's allowance. Aqua orders are controlled through the maker's Aqua position.

## Testing

Run every shape through [`CoreInvariants`](../test/solidity/invariants/CoreInvariants.t.sol) in both directions and both exact modes, on the router it targets:

```solidity
contract MyProgramTest is Test, OpcodesDebug, CoreInvariants {
    function test_Invariants() public {
        ISwapVM.Order memory order = _createOrder(buildMyProgram());

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }
}
```

Full example: [`ExampleInvariantUsage.t.sol`](../test/solidity/invariants/ExampleInvariantUsage.t.sol); per-shape setups in [`test/solidity/invariants/`](../test/solidity/invariants/). Program-specific cases the harness does not generate: each jump target and branch, dust and over-capacity amounts, fills spread over the auction or decay window, and state before and after fills.
