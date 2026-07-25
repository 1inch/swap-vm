# AGENTS.md

## Cursor Cloud specific instructions

SwapVM is a Solidity protocol (a programmable token-swap VM). There is no GUI; validate work with the terminal. Both Hardhat and Foundry test runners work against the same `test/*.sol` suite (771 tests). Standard scripts live in `package.json`; deploy flow is in `DEPLOY.md`.

The update script installs deps and Foundry on boot (`yarn install`, plus `foundryup` into `$HOME/.foundry/bin`, which the installer adds to `~/.bashrc`). Both toolchains are ready at session start. Key non-obvious notes:

- Core dev loop needs no external services or chain. `yarn test` (`npx hardhat test`) and `forge test` both compile and run the ~771 Solidity tests in `test/*.sol` in an in-process EVM.
- `forge test` is fast (~2s using cached build) and prints a clean pass/fail total; `yarn test` is the CI gate. They exercise the same suite.
- First-time compilation is slow (~7 min for Hardhat, similar for `forge build`) because of `viaIR` (see `hardhat.config.ts` / `foundry.toml`); cost is dominated by test contracts. Subsequent runs reuse cached artifacts.
- `yarn snapshot:check` and `yarn snapshot` run `npx hardhat clean` first, forcing a full Hardhat recompile (~7 min each) on top of the test run.
- `snapshot:check` printing "N function(s) produced by this run are not in the snapshot" is informational (new fuzz functions); it still exits success as long as it prints "Snapshot check passed".
- Foundry (`forge`/`anvil`/`cast`) is also needed for the optional `yarn snapshot:e2e` (`scripts/snapshot-e2e.sh`, spawns anvil) and Foundry deploy scripts. `forge remappings` resolve to `node_modules/` (see `remappings.txt`), so `yarn install` must run before `forge build`.
- There is no lint step (no `solhint`/`slither`/`yarn lint`); `forge build` emits `forge-lint` warnings but they are non-blocking, and `forge fmt` config exists but is not enforced.
- CI (`.github/workflows/ci.yml`) uses Node 24 and Hardhat only; the environment runs Node 22, which works fine for Hardhat 3 and Foundry.
