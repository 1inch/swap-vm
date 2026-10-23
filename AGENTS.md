# AGENTS.md

Guidance for coding agents working in this repository.

## What this repository is

SwapVM is a virtual machine for programmable token swaps: a maker signs an order (or ships it to Aqua) whose bytecode program prices the swap, and a taker executes it, with no per-strategy contract deployment. This repository holds the SwapVM contracts, the three routers built on them (`SwapVMRouter`, `LimitSwapVMRouter`, `AquaSwapVMRouter`), their tests, and the Hardhat Ignition modules that deploy the routers.

## Toolchain

This project uses Hardhat 3 (`hardhat.config.ts`), with solc pinned to 0.8.30, `viaIR` and `evmVersion` `prague`. There is no GUI; validate work with the Hardhat test suite.

### Build and test

The commands to build and test this repository are in [the README's Development section](README.md#development), the one place they are kept. Run those rather than inventing parallel ones. The repository has no linter or formatter; do not introduce `forge fmt`, Prettier, solhint or another one unless asked.

## Layout

| Path | Contents |
|---|---|
| `contracts/` | `SwapVM.sol`, the instruction libraries (`instructions/`), the opcode sets (`opcodes/`), the routers built from them (`routers/`), canonical strategy builders (`strategies/`), extensions such as `NativeOrderFactory` (`extensions/`), shared libraries including `OpcodeList.sol` (`libs/`) and interfaces |
| `test/solidity/` | Solidity tests run by Hardhat, including fuzz tests, `CoreInvariants` and the gas tests under `gas/` |
| `test/typescript/` | TypeScript tests run by Hardhat's Node.js test runner |
| `ignition/` | Hardhat Ignition modules that deploy the three routers, and per-chain constructor parameters in `ignition/parameters/` |
| `snapshots/` | Gas measurements the gas tests write through the snapshot cheatcodes; `.gas-snapshot` at the root holds the per-test snapshot |
| `docs/` | The programs catalog (`PROGRAMS.md`) and the SwapVM 1.0 whitepaper (PDF) |
| `LICENSES/` | Full licence texts for SwapVM and the third-party code it uses |
| `.github/` | The CI, TAG, CREATE_RELEASE and PUBLISH workflows, which call 1inch/ci-workflow-protocol |

Contracts live under `contracts/`, tests under `test/` and deployment modules under `ignition/`. Protocol docs are Markdown under `docs/` (PDF only for whitepapers and math-heavy papers) — never commit HTML/CSS/JS documentation sites.

## Deployments and security

- Deployed routers: [the README's Deployment section](README.md#deployment). Deployment procedure: [DEPLOY.md](DEPLOY.md).
- Vulnerability disclosure and bounty: [SECURITY.md](SECURITY.md). Never open a public issue or PR for an undisclosed vulnerability.

## Agent constraints

- Do not commit secrets, private keys, mnemonics or API keys. Do not edit a file only to delete a leaked secret — report it for rotation instead.
- Do not rewrite `SPDX-License-Identifier` headers.
- Do not change the optimizer runs, `viaIR` or `evmVersion` in `hardhat.config.ts` unless explicitly asked — that changes bytecode.
- Keep diffs scoped: no drive-by reformatting of files you are not changing.
- Follow existing Solidity style and NatSpec conventions; public/external functions need accurate NatSpec.

## Project-specific notes

- Instruction order inside a program is security-critical: the same instructions in another order price differently. `DynamicBalances` and the fee instructions wrap the rest of the program through `ctx.runLoop()`, so they come first. See [docs/PROGRAMS.md](docs/PROGRAMS.md).
- Opcode numbers are fixed in `contracts/libs/OpcodeList.sol`, banked by family. Signed orders and shipped strategies carry those numbers in their bytecode, so renumbering an opcode changes what existing programs do.
- The routers are not upgradeable. Their only privileged role is the owner, limited to `rescueFunds` for tokens stuck in a router.
- The debug opcodes (`Print*`, `PatchSwapRegisters`) exist only in the `*Debug` routers; the Ignition modules deploy only the three routers above.
- Compilation is slow (~7 min) because of `viaIR`, and the cost is dominated by test contracts. The test command reuses cached artifacts and is fast (~10 s) once compiled; the snapshot commands run `npx hardhat clean` first and recompile everything.
- The snapshot check printing "N function(s) produced by this run are not in the snapshot" is informational (new fuzz functions); it passes as long as it prints "Snapshot check passed". When a change moves gas on purpose, regenerate the snapshot with `yarn snapshot`.
- CI uses Node 24; Node 22 also works for Hardhat 3. In Cursor Cloud, dependencies are already installed on session start.
