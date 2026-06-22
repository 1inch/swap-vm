import { defineConfig, configVariable } from "hardhat/config";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatIgnoreWarnings from "hardhat-ignore-warnings";

const swapVmCompiler = {
  version: "0.8.30",
  settings: {
    optimizer: {
      enabled: true,
      runs: 700,
      details: {
        yul: true,
        yulDetails: {
          stackAllocation: true,
          optimizerSteps:
            "dhfoDgvulfnTUtnIf[xa[r]EscLMcCTUtTOntnfDIulLculVcul Tpeul]jmul[jul] VcTOcul jmul : fDnTOcmu",
        },
      },
    },
    viaIR: true,
  },
};

export default defineConfig({
  plugins: [
    hardhatIgnoreWarnings,
    hardhatIgnition,
    hardhatKeystore,
    hardhatVerify,
  ],
  solidity: {
    splitTestsCompilation: true,
    profiles: {
      default: { compilers: [swapVmCompiler] },
      production: { compilers: [swapVmCompiler] },
    },
  },
  paths: {
    sources: "./src",
  },
  test: {
    solidity: {
      fsPermissions: {
        dangerouslyReadWriteDirectory: ["./deployments", "./config"],
      },
    },
  },
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
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
  warnings: {
    "test/**/*": {
      "initcode-size": "off",
    },
    "src/routers/*Debug.sol": {
      "code-size": "off",
    },
    "npm/@1inch/**/*": {
      "transient-storage": "off",
    },
  },
});
