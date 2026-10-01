import { defineConfig, configVariable } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import hardhatIgnoreWarnings from "hardhat-ignore-warnings";

const swapVmCompiler = {
  version: "0.8.30",
  settings: {
    optimizer: { enabled: true, runs: 700 },
    viaIR: true,
  },
  isolated: true,
  preferWasm: false,
};

const fastTestCompiler = {
  version: "0.8.30",
  settings: {
    viaIR: true,
    optimizer: {
      enabled: true,
      runs: 1,
      details: {
        yul: true,
        cse: false,
        constantOptimizer: false,
        inliner: false,
        peephole: false,
        jumpdestRemover: false,
        orderLiterals: false,
        deduplicate: false,
      },
    },
  },
  isolated: false,
  preferWasm: false,
};

export default defineConfig({
  plugins: [
    hardhatIgnoreWarnings,
    hardhatEthers,
    hardhatIgnition,
    hardhatKeystore,
    hardhatVerify,
    hardhatNodeTestRunner,
  ],
  solidity: {
    npmFilesToBuild: ["@1inch/solidity-utils/contracts/mocks/TokenMock.sol"],
    splitTestsCompilation: true,
    profiles: {
      default: { compilers: [swapVmCompiler] },
      production: { compilers: [swapVmCompiler] },
      fast: { compilers: [fastTestCompiler] },
    },
  },
  coverage: {
    skipFiles: [
      "contracts/opcodes/Opcodes.sol",
      "contracts/opcodes/*Debug.sol",
      "contracts/routers/SwapVMRouter.sol",
      "contracts/routers/*Debug.sol",
    ],
  },
  test: {
    solidity: {
      fuzz: {
        runs: 1024,
      },
      fsPermissions: {
        readDirectory: ["./node_modules/@1inch/solidity-utils/dist/src"],
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
  },
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
  warnings: {
    "test/solidity/**/*": {
      "initcode-size": "off",
    },
    "contracts/routers/*Debug.sol": {
      "code-size": "off",
    },
    "contracts/routers/SwapVMRouter.sol": {
      "code-size": "off",
    },
    "npm/@1inch/solidity-utils@*/**/*": {
      "transient-storage": "off",
    },
  },
});
