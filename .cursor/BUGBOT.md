# Bugbot — SwapVM

## Context

SwapVM is a programmable token-swap protocol. Orders carry bytecode programs:

```
[opcode: 1 byte][argsLength: 1 byte][args: argsLength bytes]
```

Core flow: `router.swap` → extract program from `order.traits.program(order.data)` → VM executes instructions → transfers / hooks.

Key paths:

- Core VM: `src/SwapVM.sol`
- Instructions: `src/instructions/`
- Opcodes: `src/opcodes/`
- Libraries: `src/libs/` (`VM.sol`, `MakerTraits.sol`, `TakerTraits.sol`, …)
- Routers: `src/routers/`
- Interfaces: `src/interfaces/`

Stack: Solidity 0.8.30, Hardhat-first tests (`yarn test` / `npx hardhat test`). Prefer `@1inch/solidity-utils` over OpenZeppelin equivalents for ERC20, ECDSA, reentrancy, calldata, WETH receive, Simulator.

Extended security checklist (include when reviewing instructions / math / fees): [Security Review Guidelines](./rules/security-review.mdc)

## Priority

Focus on **correctness and security of value-moving code**. Skip style nits, formatting, NatSpec completeness, and pure refactors with no behavioral change.

Risk order (highest first):

1. Token transfers, approvals, ETH/WETH handling
2. Signature / EIP-712 / invalidators / replay
3. Swap math, fees, rounding, quote vs swap divergence
4. Reentrancy / `isStaticContext` state writes
5. Opcode encoding / calldata parsing / PC jumps
6. Access control on routers / hooks / external callbacks

## What to flag

### Value & accounting

- Missing or inverted Checks-Effects-Interactions around external calls / transfers.
- Unsafe ERC20: bare `transfer`/`transferFrom`/`approve` instead of `SafeERC20` from `@1inch/solidity-utils`.
- Importing `IERC20` from OpenZeppelin when `@1inch/solidity-utils` already exports it.
- Using OZ `ReentrancyGuard` / OZ ECDSA instead of `TransientLockUnsafe` / `@1inch/solidity-utils` ECDSA.
- State writes during quote / static paths when `ctx.vm.isStaticContext` is true (invalidators, balances, decay, etc. must no-op or skip writes).
- Quote path returning different amounts than the corresponding swap for the same inputs.

### Swap instructions & math

- Direction-dependent params (`tokenIn < tokenOut`) not swapped correctly for reverse swaps.
- Rounding that favors the taker: ExactIn must round output **down**; ExactOut must round input **up** (`Math.ceilDiv`).
- Missing `isExactIn` / ExactOut branch, or fee applied on the wrong side.
- Division by zero, overflow in intermediate products, or silent precision loss that can drain over many fills.
- Invariant / K-product regressions (pool can be drained or round-tripped for profit).
- Fee logic that breaks expected additivity (flag only if clearly wrong for that fee type, not as a style preference).

### VM / opcodes / encoding

- Args length mismatches, unvalidated calldata slices, or PC jumps that skip validation / invalidation.
- New opcodes not wired in the correct opcode table (`Opcodes` / `LimitOpcodes` / `AquaOpcodes` and Debug variants).
- Changes to program encoding or `MakerTraits`/`TakerTraits` bit layouts without matching encode/decode and tests.
- Maker hooks / taker callbacks that can re-enter `swap` unsafely or trust attacker-controlled return data.

### Auth & replay

- Weakened or removed invalidator / bit-map / nonce checks.
- Signature verification changes that accept malleable or unbound messages.
- Order hash / maker scoping bugs that allow cross-maker replay.

### Tests (when `test/` changes)

- New mocks defined inline inside a test file (must live in `test/mocks/`).
- `vm.expectRevert()` without a specific error selector.
- Removed or gutted security property tests (round-trip, drain, sandwich, split, overflow, quote/swap consistency, rounding favors maker) without replacement.
- Snapshot / gas files changed in ways that hide real regressions (e.g. deleting checks rather than updating expected values intentionally).

### Dependencies & CI

- New or upgraded deps with copyleft licenses (GPL/AGPL) or unaudited swap-critical libraries.
- CI that skips Solidity tests or snapshot checks for production contract changes.

## What to leave alone

- Pure formatting, comment-only, or NatSpec-only diffs.
- Gas snapshot / opcode gas JSON updates that accompany intentional gas work (`snapshots/`, `.gas-snapshot`) unless the PR also weakens assertions.
- Generated Hardhat / Foundry artifacts (`artifacts/`, `cache/`, `out/`, `typechain-types/` if present).
- Lockfile churn without dependency intent.
- Docs-only PRs (`*.md` outside `.cursor/BUGBOT.md`), license files, and deploy notes unless they contradict code behavior.
- Debug opcode / `*Debug.sol` console logging noise unless it ships to production routers.
- Suggesting OpenZeppelin replacements for patterns that already correctly use `@1inch/solidity-utils` or `@1inch/aqua`.
- “Add more tests” as a generic comment when no concrete missing property is identified.
- Style preferences (naming, file layout) that do not affect correctness.

## Tone

Be direct. Point at the line. State the failure mode and a concrete fix. No “consider,” “you may want to,” or PR summaries. If nothing meets the bar above, say nothing.
