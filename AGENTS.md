# AGENTS.md

## Cursor Cloud specific instructions

SwapVM is a Hardhat-first Solidity protocol (a programmable token-swap VM). There is no GUI; validate work with the terminal (Hardhat Solidity tests). Standard scripts live in `package.json`; deploy flow is in `DEPLOY.md`.

Dependencies (`yarn install`, per the update script) are already installed on session start. Key non-obvious notes:

- Core dev loop needs no external services or chain. `yarn test` (`npx hardhat test`) compiles and runs the ~771 Solidity tests in `test/*.sol` in Hardhat's in-process EVM.
- Compilation is slow (~7 min) because of `viaIR` (see `hardhat.config.ts` / `foundry.toml`). `yarn build` compiles; the compile cost is dominated by test contracts.
- `yarn snapshot:check` and `yarn snapshot` run `npx hardhat clean` first, forcing a full recompile (~7 min each) on top of the test run. `yarn test` reuses cached artifacts and is fast (~10s) once compiled.
- `snapshot:check` printing "N function(s) produced by this run are not in the snapshot" is informational (new fuzz functions); it still exits success as long as it prints "Snapshot check passed".
- Tests live under `test/` but are run through Hardhat, not `forge test`. Foundry (`forge`/`anvil`) is NOT installed and is only needed for the optional `yarn snapshot:e2e` (`scripts/snapshot-e2e.sh`, spawns anvil) and Foundry deploy scripts.
- There is no lint step (no `solhint`/`slither`/`yarn lint`); `forge fmt` config exists but is not enforced.
- CI (`.github/workflows/ci.yml`) uses Node 24; the environment runs Node 22, which works fine for Hardhat 3.
