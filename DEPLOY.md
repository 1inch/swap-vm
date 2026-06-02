# SwapVM Deployment Guide

SwapVM is deployed with [Hardhat Ignition](https://hardhat.org/ignition) and verified with `hardhat-verify`.

## Prerequisites

- Node.js + Yarn (`yarn install`)
- A funded deployer key and an RPC URL for the target network
- For verification: an Etherscan API key (v2 — a single key works across all chains)

## 1. Configure secrets (config variables)

RPC URLs and the deployer private key are Hardhat **configuration variables**. Hardhat 3 does **not** auto-load `.env`; provide them either as environment variables of the same name, or via the encrypted keystore:

```bash
# Option A — environment variables
export SEPOLIA_RPC_URL=https://...
export SEPOLIA_PRIVATE_KEY=0x...
export ETHERSCAN_API_KEY=...

# Option B — encrypted keystore (prompts for a password when the value is needed)
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set ETHERSCAN_API_KEY
```

Configured networks live in `hardhat.config.ts` (`localhost`, `sepolia`, `mainnet`); add more by copying the pattern. See `.env.example` for the full list of variable names.

## 2. Set deployment parameters

Each network has a parameter file at `ignition/parameters/chain-<chainId>.json` (e.g. `chain-11155111.json` for Sepolia) holding the router constructor arguments, shared by all three routers via Ignition's `$global` key:

```json
{
    "$global": {
        "aqua": "0x…",
        "weth": "0x…",
        "owner": "0x…",
        "name": "SwapVMRouter",
        "version": "1.0.0"
    }
}
```

Fill in the `0x0000…` placeholders before deploying (`aqua` and `owner` are placeholders; canonical WETH is pre-filled for mainnet/sepolia). All five values are required — a missing one fails Ignition's validation before any transaction is sent.

## 3. Deploy

Deploy with `hardhat ignition deploy`, passing the module path, the target network, and the matching parameter file:

```bash
npx hardhat ignition deploy <modulePath> \
  --network <network> \
  --parameters ignition/parameters/chain-<chainId>.json
```

The deployable modules live in `ignition/modules/`:

| Module                                  | Contract          |
| --------------------------------------- | ----------------- |
| `ignition/modules/SwapVMRouter.ts`      | SwapVMRouter      |
| `ignition/modules/AquaSwapVMRouter.ts`  | AquaSwapVMRouter  |
| `ignition/modules/LimitSwapVMRouter.ts` | LimitSwapVMRouter |

`--network` is any network defined in `hardhat.config.ts` (`localhost`, `sepolia`, `mainnet`). Make sure the `--parameters` file matches the network's chain id.

```bash
# Deploy SwapVMRouter to Sepolia (chain id 11155111)
npx hardhat ignition deploy ignition/modules/SwapVMRouter.ts \
  --network sepolia --parameters ignition/parameters/chain-11155111.json

# Deploy and verify in one step (see step 4)
npx hardhat ignition deploy ignition/modules/SwapVMRouter.ts \
  --network sepolia --parameters ignition/parameters/chain-11155111.json --verify

# Wipe local state and redeploy
npx hardhat ignition deploy ignition/modules/LimitSwapVMRouter.ts \
  --network localhost --parameters ignition/parameters/chain-31337.json --reset
```

Ignition is idempotent and resumable: re-running a deploy continues from where it left off and skips completed steps. By default the deployment id is `chain-<chainId>` and artifacts (addresses + journal) are written to `ignition/deployments/chain-<chainId>/`. Real-network deployments are committed (so resume works across machines/CI); the throwaway local `chain-31337` deployment is git-ignored.

## 4. Verify

Add `--verify` to the deploy command — Ignition verifies every contract in the deployment and supplies the recorded constructor arguments automatically (no manual ABI encoding). Requires `ETHERSCAN_API_KEY`.

`--verify` also works on an **already-deployed** deployment: re-run the same deploy command with `--verify`, and since everything is already deployed Ignition skips the transactions and just verifies the recorded contracts.

```bash
# Verify an existing deployment by re-running deploy with --verify
npx hardhat ignition deploy ignition/modules/SwapVMRouter.ts \
  --network sepolia --parameters ignition/parameters/chain-11155111.json --verify
```

Equivalently, verify a recorded deployment by its id:

```bash
npx hardhat ignition verify chain-11155111
```
