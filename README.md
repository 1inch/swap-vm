# SwapVM

[![Github Release](https://img.shields.io/github/v/tag/1inch/swap-vm?sort=semver&label=github)](https://github.com/1inch/swap-vm/releases/latest)
[![CI](https://github.com/1inch/swap-vm/actions/workflows/ci.yml/badge.svg)](https://github.com/1inch/swap-vm/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@1inch/swap-vm.svg)](https://www.npmjs.com/package/@1inch/swap-vm)
[![License](https://img.shields.io/badge/License-Degensoft--SwapVM--1.1-orange)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-blue)](https://docs.soliditylang.org/en/v0.8.30/)

**A virtual machine for programmable token swaps.** A maker signs an order (or ships it to Aqua) whose bytecode program prices the swap; a taker executes it. No per-strategy contract deployment.

- [Programs catalog](docs/PROGRAMS.md) — strategy types, composition rules, security notes
- [Whitepaper](docs/whitepaper-swap-vm-1.0.pdf)
- [Deployment guide](DEPLOY.md)

## How it works

An **order** is `{ maker, traits, data }`. `traits` packs flags, the receiver and slice offsets; `data` holds the token pair (`tokenA < tokenB`), optional hook payloads and the **program**.

A **program** is a sequence of instructions:

```
[opcode: 1 byte][argsLength: 1 byte][args: argsLength bytes]
```

Opcode numbers are fixed in [`OpcodeList.sol`](contracts/libs/OpcodeList.sol), banked by family: control `0x00`, debug `0x10`, guards and conditional jumps `0x20`, invalidators `0x40`, curves `0x50`, fees `0x70`, balances `0x90`, rates `0xb0`; `0xf0+` is reserved.

**Swap flow.** The taker calls `swap(order, amount, takerTraitsAndData)`, fixing one side (`isExactIn`) and the direction (`isAToB`). The VM runs the program over a `Context`:

```
Context
├── vm     isStaticContext, nextPC, programPtr, takerArgsPtr, dispatch
├── query  orderHash, maker, taker, tokenIn, tokenOut, isExactIn   (read-only)
├── swap   balanceIn, balanceOut, amountIn, amountOut              (registers)
└── fee    protocol fees to settle in the transfer phase
```

Instructions set balances, apply curves, fees and guards, and leave the missing amount in the registers. After `runLoop()` SwapVM validates maker and taker constraints, runs hooks and callbacks, and moves tokens. `quote()` runs the same program in a static context (`router.asView().quote(...)`), so quote and swap agree.

**Authorization** is one of:

- **Signature** — EIP-712 over `Order(address maker, uint256 traits, bytes data)`, verified on every fill.
- **Aqua** (`useAquaInsteadOfSignature`) — no signature; `orderHash = keccak256(abi.encode(order))`, balances are read from and settled through [1inch Aqua](https://github.com/1inch/aqua) (`safeBalances`, `pull`, `push`). Custom receiver and WETH unwrapping are not allowed in this mode.

**Balances** come from one of three sources:

| Source  | Instruction       | State                          | Typical use                        |
|---------|-------------------|--------------------------------|------------------------------------|
| Static  | `StaticBalances`  | none, fixed rate               | limit orders, auctions, RFQ        |
| Dynamic | `DynamicBalances` | stored in SwapVM per orderHash | isolated AMM positions             |
| Aqua    | none              | Aqua balances                  | shared liquidity across strategies |

## Instructions

Every instruction is a library with `opcode`, `build(...)`, `parse(...)` and `exec(ctx, args)`.

| Family       | Instructions |
|--------------|--------------|
| Control      | `Stop`, `Revert`, `Salt`, `Jump`, `Extruction` (delegate registers to a maker-chosen contract) |
| Guards       | `Deadline`, `JumpIfDirection`, `JumpIfTokenIn`, `JumpIfTokenOut`, `PrivateOrder`, `WhitelistCoequal`, `WhitelistSequential`, `OnlyTakerTokenBalanceNonZero`, `OnlyTakerTokenBalanceGte`, `OnlyTakerTokenSupplyShareGte`, `OnlyTxOriginTokenBalanceNonZero` |
| Invalidation | `InvalidateBit` (one-shot nonce), `InvalidateTokenIn` / `InvalidateTokenOut` (cap cumulative fills), `ValidateSeriesEpoch` (cancel a series by bumping its epoch) |
| Balances     | `StaticBalances`, `DynamicBalances`, `DutchAuctionBalanceIn` / `Out`, `PiecewiseLinearScaleBalanceIn` / `Out`, `Decay` (time-decaying virtual balances) |
| Curves       | `LimitSwap`, `LimitSwapFullAmount`, `XYCSwap` (x·y=k), `XYCConcentrateSwap` (price range), `PeggedSwap` |
| Rates        | `RequireMinRate`, `AdjustMinRate`, `OraclePriceAdjuster` (Chainlink), `BaseFeeAdjuster` (gas-aware) |
| Fees         | `FeeFlatIn` / `FeeFlatOut` (LP fee, `BPS = 1e7`), `FeeProtocol` (third-party flat and surplus fees; fixed receivers or an `IProtocolFeeProvider`) |
| Debug        | `Print*`, `PatchSwapRegisters` — only in `*Debug` routers |

> Instruction order is security-critical: the same instructions in another order price differently. `DynamicBalances` and fee instructions wrap the rest of the program through `ctx.runLoop()`, so they come first. Audit every program before production use. See [PROGRAMS.md](docs/PROGRAMS.md).

## Routers

A router is `SwapVM` plus an opcode set, wired together in `_dispatch`.

| Router              | Opcode set     | Scope |
|---------------------|----------------|-------|
| `SwapVMRouter`      | `Opcodes`      | full instruction set |
| `LimitSwapVMRouter` | `LimitOpcodes` | 1D strategies: `StaticBalances`, `LimitSwap*`, invalidators, epochs, whitelists, `PiecewiseLinearScale*`, `BaseFeeAdjuster`, `FeeProtocol`, `Extruction` |
| `AquaSwapVMRouter`  | `AquaOpcodes`  | AMM curves, `Decay`, `FeeFlatIn`, `FeeProtocol`, guards — for Aqua-shipped strategies |

`*Debug` variants add the debug opcodes. Every router also includes `Simulator` (`simulate`), `Rescuable` (`rescueFunds`, owner-only) and `OrderRegistrator`.

```solidity
contract MyRouter is SwapVM, Opcodes {
    constructor(address aqua, address weth, address owner)
        SwapVM(aqua, weth, owner, "MyRouter", "1") {}

    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        _runOpcode(ctx, opcode, args); // or route to your own instruction libraries
    }
}
```

## Makers

### Limit order

```solidity
// Sell 0.5 WETH for 1000 USDC. USDC < WETH by address, so USDC is tokenA.
bytes memory program = bytes.concat(
    StaticBalances.build(1000e6, 0.5e18), // (balanceA, balanceB)
    LimitSwap.build(USDC, WETH),          // taker pays USDC, receives WETH
    InvalidateTokenOut.build()            // partial fills, capped at 0.5 WETH in total
);

ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
    maker: maker,
    receiver: address(0),                 // 0 = maker
    tokenA: USDC,
    tokenB: WETH,
    shouldUnwrapWeth: false,
    useAquaInsteadOfSignature: false,
    allowZeroAmountIn: false,
    hasPreTransferInHook: false,  hasPostTransferInHook: false,
    hasPreTransferOutHook: false, hasPostTransferOutHook: false,
    preTransferInTarget: address(0),  preTransferInData: "",
    postTransferInTarget: address(0), postTransferInData: "",
    preTransferOutTarget: address(0), preTransferOutData: "",
    postTransferOutTarget: address(0), postTransferOutData: "",
    program: program
}));

bytes32 orderHash = router.hash(order); // EIP-712 digest, sign off-chain
```

### AMM position

```solidity
bytes memory program = bytes.concat(
    DynamicBalances.build(100_000e6, 50e18), // initial reserves, then persisted per orderHash
    FeeFlatIn.build(0.003e7),                // 0.3% LP fee
    XYCSwap.build()                          // x*y=k
);
```

With `useAquaInsteadOfSignature: true`, drop `DynamicBalances`: reserves come from Aqua after `aqua.ship(...)`. The curve bytecode is the same in both modes.

### Hooks

`IMakerHooks.{pre,post}Transfer{In,Out}` run around each transfer, on the maker or on a target contract encoded in `order.data`. The taker may pass per-hook data.

### Checklist

- Add `Deadline`. Use `InvalidateBit` for one-shot orders, `InvalidateTokenIn` / `InvalidateTokenOut` for partial fills, `ValidateSeriesEpoch` to cancel a whole series at once.
- Guard rates with `RequireMinRate` or `AdjustMinRate`; consider `Decay` for AMM positions.
- `Salt` makes otherwise identical orders hash differently.
- Approve the router: `tokenOut` is pulled from the maker with `transferFrom` (signature mode) or Aqua `pull`.

## Takers

```solidity
bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
    taker: address(this),
    isExactIn: true,                       // `amount` is the input amount
    isAToB: true,                          // pay tokenA, receive tokenB
    allowPartialFill: false,               // true: fill up to `amount`, threshold scales pro rata
    shouldUnwrapWeth: false,               // unwrap WETH received as tokenOut
    isStrictThresholdAmount: false,        // true: require the exact threshold amount
    isFirstTransferFromTaker: false,       // default: maker's tokenOut is sent first
    useTransferFromAndAquaPush: false,     // Aqua orders: pay via transferFrom instead of pre-pushing
    threshold: abi.encodePacked(minOut),   // 32 bytes (min out / max in) or empty
    to: address(0),                        // 0 = taker
    deadline: uint40(block.timestamp + 5 minutes),
    hasPreTransferInCallback: false, hasPreTransferOutCallback: false,
    preTransferInHookData: "",  postTransferInHookData: "",
    preTransferOutHookData: "", postTransferOutHookData: "",
    preTransferInCallbackData: "", preTransferOutCallbackData: "",
    instructionsArgs: "",                  // read by instructions via ctx.tryChopTakerArgs()
    signature: signature                   // empty for Aqua orders
}));

(uint256 quotedIn, uint256 quotedOut,) = router.asView().quote(order, 1000e6, takerData);
(uint256 amountIn, uint256 amountOut,)  = router.swap(order, 1000e6, takerData);
```

- Reuse the same `takerData` for `quote` and `swap`.
- Send ETH with `swap` when `tokenIn` is WETH; SwapVM wraps it and refunds the excess.
- By default the maker's `tokenOut` is transferred first, so `ITakerCallbacks.preTransferInCallback` can source `tokenIn` flash-swap style. Set `isFirstTransferFromTaker` to pay first.

## Order registry and canonical strategies

- `registerOrder(order, signature)` verifies the order (signature or Aqua balances), records `announcedAt[orderHash]` and emits `OrderRegistered` — on-chain publication for indexers.
- [`Strategies`](contracts/strategies/Strategies.sol) builds canonical bytecode from typed arguments (`buildLimitOrder`, `buildXYCConcentrateOrder`) behind an allow-listed prefix of validation-only instructions, so integrators can verify a program's shape on-chain.

## Core invariants

Every program should hold these; [`CoreInvariants`](test/solidity/invariants/CoreInvariants.t.sol) checks them:

1. **Symmetry** — `exactIn(X) → Y` implies `exactOut(Y) → X` within rounding.
2. **Additivity** — splitting a swap must not beat a single swap (sub-additive; strictly additive is the ideal).
3. **Quote/swap consistency** — `quote` returns what `swap` executes.
4. **Monotonicity** — larger trades get an equal or worse price.
5. **Rounding favors the maker** — `amountIn` rounds up, `amountOut` rounds down.
6. **Balance sufficiency** — revert when `amountOut > balanceOut`.
7. **Liveness** — a depleted side can be refilled by swapping the other way.

```solidity
contract MyProgramTest is Test, OpcodesDebug, CoreInvariants {
    function test_Invariants() public {
        ISwapVM.Order memory order = _createOrder(buildMyProgram());

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // config.skipAdditivity / skipMonotonicity for stateless or fixed-rate programs

        assertAllInvariantsWithConfig(swapVM, order, address(tokenA), address(tokenB), config);
    }
}
```

Full example: [`ExampleInvariantUsage.t.sol`](test/solidity/invariants/ExampleInvariantUsage.t.sol).

## Security

- Per-order transient reentrancy lock (EIP-1153) around `swap`.
- EIP-712 signed orders; Aqua orders are authorized by Aqua balances.
- Programs can only combine the router's instruction set; settlement happens in SwapVM after the program, never inside an instruction. `Extruction` calls a maker-chosen contract — treat it as strategy risk.
- The owner role is limited to `rescueFunds` for tokens stuck in the router.
- Audit: [OpenZeppelin — 1inch Aqua and SwapVM MVP v1.0](https://www.openzeppelin.com/news/1inch-aqua-and-swapvm-mvp-v1.0-audit).
- Contact: security@1inch.io

## Deployment

Release **v1.0.x** router: `0x111111338c5091E8440b67B168bAe16a668AC0De` on Ethereum, Base, Optimism, Polygon, Arbitrum, Avalanche, BNB Chain, Linea, Sonic, Unichain, Gnosis, zkSync, Cronos, Monad and HyperEVM. It exposes the v1.0 ABI, `swap(order, tokenIn, tokenOut, amount, takerData)`.

`main` uses `swap(order, amount, takerTraitsAndData)` and is deployed with Hardhat Ignition — see [DEPLOY.md](DEPLOY.md).

## Development

```bash
yarn install
yarn build           # hardhat compile (viaIR, slow on first run)
yarn test            # Solidity and TypeScript tests
yarn snapshot:check  # gas snapshots
```

```bash
npm install @1inch/swap-vm
```

## License

`LicenseRef-Degensoft-SwapVM-1.1` — see [LICENSE](LICENSE), [LICENSES/](LICENSES) and [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). Licensing inquiries: license@degensoft.com, legal@degensoft.com.
