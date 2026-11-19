import { defineConfig, configVariable } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import hardhatContractSizer from "@solidstate/hardhat-contract-sizer";
import hardhatIgnoreWarnings from "hardhat-ignore-warnings";

const solc = (runs: number) => ({
  version: "0.8.30",
  settings: {
    optimizer: { enabled: true, runs },
    viaIR: true,
  },
  preferWasm: false,
});

// Deployed routers, runs are set per router to fit the 24576-byte code size limit
const deployedRouters = {
  "contracts/routers/LimitSwapVMRouter.sol": solc(600),
  "contracts/routers/AquaSwapVMRouter.sol": solc(600),
};

const fastTestCompiler = {
  version: "0.8.30",
  settings: {
    evmVersion: "prague",
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
    hardhatContractSizer,
  ],
  solidity: {
    npmFilesToBuild: ["@1inch/solidity-utils/contracts/mocks/TokenMock.sol"],
    splitTestsCompilation: true,
    profiles: {
      default: { isolated: true, compilers: [solc(600)], overrides: deployedRouters },
      production: { isolated: true, compilers: [solc(600)], overrides: deployedRouters },
      fast: { isolated: true, compilers: [fastTestCompiler] },
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
  contractSizer: {
    only: [/contracts\/routers\//],
    except: [/Debug/],
  },
  warnings: {
    "test/solidity/**/*": {
      "initcode-size": "off",
      "func-mutability": "off",
      "unused-param": "off",
      "unused-var": "off",
      "unused-call-retval": "off",
    },
    "test/solidity/helpers/SwapVMTestSetup.sol": {
      "shadowing": "off",
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
