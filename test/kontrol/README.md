# Kontrol proofs for SwapVM instructions

Formal verification of SwapVM instructions using [Kontrol](https://docs.runtimeverification.com/kontrol),
Runtime Verification's symbolic execution engine for Foundry.

Kontrol reinterprets ordinary Solidity property tests as formal specifications: every test
parameter becomes a symbolic variable, and the tool explores *all* reachable execution paths
against [KEVM](https://github.com/runtimeverification/evm-semantics), a complete formal
semantics of the EVM. The result is either a machine-checked proof that the assertions hold
for every input, or a concrete counterexample with the path condition that produced it.

Verification is at the **bytecode** level, so the compiler is inside the trust boundary
rather than outside it. This is also what makes the longer-term plan viable: a hand-written
Yul or assembly implementation can be proven equivalent to a readable Solidity reference.

## Scope

Specs target **individual instructions**, not the VM as a whole. This is deliberate:

- Instructions in the tier-1 set are `internal pure` functions over a memory struct. No
  storage, no external calls — so none of the symbolic-storage blowup that makes
  stateful contracts expensive to verify.
- `ContextLib.runLoop` dispatches through an **internal function pointer**
  (`VM.dispatch`). Symbolically executing through a function pointer forces the prover to
  branch over every possible jump destination. Verifying instructions in isolation avoids
  this entirely. Verifying the run loop itself is a separate, much harder project.

## Layout

```
lemmas.k                      shared K lemma library (repo root, wired via kontrol.toml)
kontrol.toml                  proof configuration
test/kontrol/
  README.md                   this file
  harnesses/*.sol             external surfaces over internal instructions
  *Spec.t.sol                 one spec file per instruction
```

`Context` embeds an internal function pointer, so it is not ABI-encodable and cannot be
passed across an external call. Each harness therefore takes the individual registers as
scalars and assembles the `Context` in memory. Harnesses leave `ctx.vm` zero-initialised;
this is safe only for instructions that never call `ctx.runLoop()`.

## Prerequisites

Kontrol's native installer (`kup`) is Nix-based and needs root. Where that is not
available, the published Docker image is the path of least resistance:

```bash
docker pull runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255
docker run -d --name kontrol -v "$PWD:/work" -w /work \
  runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255 sleep infinity
```

Note that the image's `kontrol` entrypoint resolves only under its internal `user` account
(uid 1010) — running as another uid fails with `ModuleNotFoundError: No module named
'kontrol'`. Either run as that user or copy the working tree to a path it owns.

Native install, where root is available:

```bash
bash <(curl https://kframework.org/install) && kup install kontrol
```

## Workflow

```bash
# Compile the K definition from the forge artifacts plus lemmas.k. Slow (minutes).
FOUNDRY_PROFILE=kontrol kontrol build

# Prove one spec. Repeat --match-test for several.
kontrol prove --match-test 'XYCSwapSpec.test_exactIn_cannotDrainPool'

kontrol list                      # proof statuses and node counts
kontrol show    <test>            # print the proof / KCFG
kontrol view-kcfg <test>          # interactive KCFG browser
kontrol show --failure-information --failing <test>   # counterexample + path condition
```

Every spec also runs as an ordinary fuzz test — `forge test --match-path test/kontrol/` —
which is the fast feedback loop while writing them. A spec that fails under the fuzzer will
certainly fail under Kontrol; one that passes may still fail, since the fuzzer only samples.

## Traps

**A stale lemma file survives `--rekompile` silently.** Kontrol copies `lemmas.k` into
`out/kompiled/requires/lemmas.k` at build time and does not always refresh that copy.
`kontrol build --rekompile` will report `✅ Success` while having compiled the *previous*
version of your lemmas — so a proof that still fails looks like "the lemmas didn't help"
when in fact they were never loaded. Always verify:

```bash
grep -c 'mul-bound-transfer' kompiled/definition.kore   # expect > 0
```

If the count is zero, refresh the copy by hand and rebuild:

```bash
cp lemmas.k kompiled/requires/lemmas.k && FOUNDRY_PROFILE=kontrol kontrol build --rekompile
```

Note the output location: in this repo `kontrol build` writes to a **top-level
`kompiled/`**, not `out/kompiled/`. The path depends on the project's foundry `out`
setting, so check `find . -maxdepth 2 -name definition.kore` before assuming either. Both
`kompiled/` and the `digest` file are gitignored — the compiled definition is ~317 MB.

This is why every rule in `lemmas.k` carries a unique label.

**`--reinit` throws away everything.** After changing lemmas the cached proof is stale, but
`--reinit` re-explores from scratch including `setUp`. Prefer pruning just the stuck
subtree and resuming:

```bash
kontrol remove-node <test> <nodeId>
kontrol prove --match-test <test>       # no --reinit; the cached prefix is reused
```

**`vm.assume` means something different here.** Under the fuzzer it rejects samples; under
Kontrol it adds a path constraint. A spec whose assumptions are near-unsatisfiable will
fail the fuzzer with `rejected too many inputs` while proving fine under Kontrol. Treat the
assumptions as part of the specification — they define the domain the property holds over.

**Gas is off by default.** See below.

## Configuration notes

`kontrol.toml` deviates from Kontrol's defaults in one way worth understanding.
`max-depth` is 2000 with `break-on-basic-blocks` and `break-on-calls` enabled, rather than
the usual 25000 with breaks disabled. Kontrol persists proof state *between* nodes, so the
distance between nodes is how much work a crash discards. With long edges, a backend crash
mid-edge loses everything since the last checkpoint and the node count stays frozen — the
proof looks hung when it is actually progressing. Frequent checkpoints cost some overhead
and buy durable, observable progress plus the ability to localise a stall to one basic
block. Raise `max-depth` for proofs known to close quickly.

`foundry.toml` gains a separate `[profile.kontrol]` rather than pinning `evm_version` in
`default`, because pinning it in `default` would change the emitted bytecode and invalidate
`.gas-snapshot`, which CI gates on. Keep `evm_version` there in sync with `schedule` in
`kontrol.toml`.

## Adding a spec for another instruction

One harness and one spec file per instruction, so concurrent work does not collide. The
only shared file is `lemmas.k`; append new rules to the relevant section rather than
editing existing ones.

1. `test/kontrol/harnesses/<Instruction>Harness.sol` — external surface, registers as scalars.
2. `test/kontrol/<Instruction>Spec.t.sol` — properties, with the reference semantics quoted
   in the doc comment.
3. `forge test --match-path test/kontrol/<Instruction>Spec.t.sol` until green.
4. `FOUNDRY_PROFILE=kontrol kontrol build && kontrol prove --match-test '<Instruction>Spec.*'`.

Derive the semantics from the **source**, not from `README.md` or the whitepaper — the
opcode numbers in both are stale relative to `src/libs/OpcodeList.sol`.

### Suggested order

Instructions classified by what the prover has to deal with:

**Tier 1** — pure, no loops, no storage, no external calls. Gas per path is constant.
`XYCSwap`, `LimitSwap`, `MinRate`, `Controls`, `FeeExperimental`.

**Tier 2** — loops or transcendental math. Correctness needs substantially more lemma work,
and gas becomes genuinely symbolic. `Whitelist` (4 loops), `PiecewiseLinearScale`,
`BaseFeeAdjuster`, `DutchAuction`, `PeggedSwap` and `XYCConcentrate` (square roots).
Anything reaching `Power.pow` hits a `while` loop with a symbolic trip count and needs
`--bmc-depth`, which yields only a bounded result.

**Tier 3** — storage or external calls; no longer pure-instruction verification.
`Balances`, `Invalidators`, `Decay`, `TWAPSwap`, `SeriesEpochManager`, `Fee` (external fee
provider), and `Extruction`, which makes arbitrary external calls and cannot be verified
without strong assumptions about the callee.

### High-value targets

`TESTING.md` documents roughly 40 tests that disable core invariants with unresolved TODOs,
and the suite contains 98 `skip*` flags in total (38 additivity, 23 symmetry, 22
monotonicity, 15 spot-price). Several scenarios also set tolerances loose enough to be
near-vacuous. Those are the places where a proof or a counterexample is worth more than
confirming that arithmetic which already works still works.

## Reasoning about gas

Gas is modelled by KEVM (`--use-gas` enables it; `--schedule` picks the hardfork) but is
disabled by default because gas terms inflate the state space.

For **tier-1 instructions** gas along a given path is a *constant*, not a symbolic
expression — there are no loops and no warm/cold storage variance — so `--use-gas` stays
tractable and can prove `new_gas <= old_gas` per path directly.

For everything else, keep gas out of the proof and recover cost information from the KCFG:

1. Prove functional equivalence with gas disabled. The KCFG leaves enumerate **all**
   execution paths — a proven-exhaustive enumeration, not a sample.
2. `kontrol get-model` on each leaf yields a concrete witness input reaching that path.
3. Measure gas concretely on each witness (`vm.startSnapshotGas`, `forge snapshot`).

Because the paths are exhaustive, per-path concrete measurement gives complete path
coverage of gas without paying for symbolic gas.

Kontrol is far too slow to sit inside a superoptimiser's search loop. Use a fast concrete
cost model to drive the search and Kontrol to validate the winner — translation validation,
not verified synthesis.
