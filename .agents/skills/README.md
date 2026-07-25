# Agent skills

Community agent skills vendored into this repo with the [`skills`](https://github.com/vercel-labs/skills)
CLI. `.agents/skills/` is the shared location read by Cursor, Claude Code, Codex, Copilot and
others, so one copy serves every agent the team uses.

Skills are on-demand playbooks: only the `name` and `description` of each are held in the agent's
context, and the body is read when the task matches. That is why this list is deliberately short —
every skill added here costs context on every request.

`skills-lock.json` in the repo root pins the upstream source and a content hash for each skill.

## Installed

| Skill | Source | Why it is here |
| --- | --- | --- |
| `dimensional-analysis` | Trail of Bits | `src/` mixes three fixed-point scales (`1e18`, `1e9`, `1e27`) on top of arbitrary token decimals. Annotates units through `PeggedSwapMath`, `Power`, `XYCConcentrate` and the fee/decay/TWAP adjusters, and flags scale mismatches. |
| `token-integration-analyzer` | Trail of Bits | `SwapVMRouter.swap` takes caller-supplied `tokenIn`/`tokenOut`, so the protocol must survive non-standard ERC20s. Checks against Trail of Bits' weird-token database (fee-on-transfer, rebasing, missing return values, blocklists). |
| `entry-point-analyzer` | Trail of Bits | Enumerates state-changing entry points and their access levels across the three router pairs, `IMakerHooks` and `ITakerCallbacks`. |
| `solidity-auditor` | Pashov Audit Group | Runs a fan-out audit over `src/`. Its `math-precision`, `asymmetry`, `boundary` and `invariant` passes line up with the properties already listed in `.cursor/rules/security-review.mdc`, and its bit-mask checks apply to `MakerTraits` and `TakerTraits`. |
| `property-based-testing` | Trail of Bits | `test/invariants/` already holds 20+ suites; this covers property design, generator strategies and reading shrunk counterexamples. |
| `differential-review` | Trail of Bits | Security-focused review of a diff rather than a snapshot, including blast radius and test-coverage checks. Complements the generic prompt in `.github/workflows/claude-code-review.yml`. |

## Evaluated and skipped

| Candidate | Reason |
| --- | --- |
| `affaan-m/everything-claude-code@defi-amm-security` | Prescribes OpenZeppelin `ReentrancyGuard` and `SafeERC20`, which contradicts `.cursor/rules/solidity-style.mdc` (this repo uses `TransientLock` and `SafeERC20` from `@1inch/solidity-utils`). |
| `wshobson/agents@solidity-security` | Generic, Hardhat/JS examples, and already covered by `.cursor/rules/security-review.mdc`. |
| `pashov/skills@fizz` | Generates an Echidna/Medusa suite under `test/fizz/` plus Node tooling. Conflicts with `.cursor/rules/foundry-tests.mdc` ("never create new test files unless explicitly requested"). Revisit if Echidna or Medusa is adopted in CI. |
| `trailofbits/skills@secure-workflow-guide` | Built around Slither, which is not in CI. Revisit alongside a Slither job. |
| `openzeppelin/openzeppelin-skills@*` | Project setup and proxy upgradeability. These contracts are already set up and are not upgradeable. |

## Licensing

The Trail of Bits skills are CC BY-SA 4.0 and the Pashov skill is MIT; both are recorded in
`THIRD_PARTY_NOTICES`. Keep the vendored files verbatim. Editing them in place produces Adapted
Material under ShareAlike — put repo-specific guidance in `.cursor/rules/` instead, which is where
`security-review.mdc`, `foundry-tests.mdc` and `solidity-style.mdc` already live.

## Working with these

```bash
npx skills list                       # what is installed
npx skills update <skill>             # pull upstream changes and refresh skills-lock.json
npx skills remove <skill> -a cursor   # drop one
```

Adding a skill: `npx skills add <owner/repo> --skill <name> -a cursor --copy`. Use `--copy` so real
files land in the repo rather than symlinks into a cache. Read what you install — skills run with
full agent permissions — and record the licence in `THIRD_PARTY_NOTICES`.

`solidity-auditor`, `dimensional-analysis` and `differential-review` write reports and scratch
directories into the repo root. Those paths are already in `.gitignore`.
