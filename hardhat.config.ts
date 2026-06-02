import { defineConfig, configVariable } from "hardhat/config";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatVerify from "@nomicfoundation/hardhat-verify";

// Migrated from foundry.toml [profile.default].
// [profile.ci] is identical to [profile.default] (same solc, optimizer, runs,
// via_ir and optimizer_details), so no separate Hardhat build profile is needed.
//
// Foundry-only sections with no Hardhat equivalent:
//   [fmt]  -> Forge's built-in formatter; `forge fmt` works standalone. No HH equivalent
//             (prettier-plugin-solidity is the usual alternative).

export default defineConfig({
  plugins: [hardhatIgnition, hardhatKeystore, hardhatVerify],
  solidity: {
    compilers: [
      {
        version: "0.8.30",
        settings: {
          // foundry: optimizer = true / optimizer_runs = 700
          optimizer: {
            enabled: true,
            runs: 700,
            // foundry: [profile.default.optimizer_details]
            details: {
              yul: true,
              yulDetails: {
                stackAllocation: true,
                optimizerSteps:
                  "dhfoDgvulfnTUtnIf[xa[r]EscLMcCTUtTOntnfDIulLculVcul Tpeul]jmul[jul] VcTOcul jmul : fDnTOcmu",
              },
            },
          },
          // foundry: via_ir = true
          viaIR: true,
        },
      },
    ],
  },
  paths: {
    // foundry: src = "src" (Forge default). Hardhat defaults to ./contracts,
    // so this must be set explicitly to preserve behavior.
    sources: "./src",
    // foundry test dir is "test" — matches Hardhat's default, no override needed.
  },
  test: {
    solidity: {
      // foundry: fs_permissions = [{ access = "read-write", path = "./deployments" },
      //                            { access = "read-write", path = "./config" }]
      // Both paths are directories -> use the recursive (directory) variant.
      // Used by script/utils/Config.sol (reads config/constants.json) under `forge script`.
      fsPermissions: {
        dangerouslyReadWriteDirectory: ["./deployments", "./config"],
      },
    },
  },
  // Deployment targets. Secrets resolve from config variables (env vars of the
  // same name, or `npx hardhat keystore set <NAME>`); Hardhat 3 does NOT auto-load .env.
  networks: {
    localhost: {
      type: "http",
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
      chainId: 11155111,
    },
    mainnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("MAINNET_RPC_URL"),
      accounts: [configVariable("MAINNET_PRIVATE_KEY")],
      chainId: 1,
    },
  },
  // Etherscan API v2 — a single key works across all supported chains.
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
});
