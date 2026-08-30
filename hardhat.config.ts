import { defineConfig } from "hardhat/config";
import HardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";

export default defineConfig({
  plugins: [HardhatToolboxMochaEthers],
  solidity: {
    version: "0.7.6",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      metadata: {
        bytecodeHash: "none",
      },
    },
  },
  paths: {
    sources: "./contracts",
    tests: {
      mocha: "./test",
      solidity: "./.hh3-tests-disabled",
    },
    cache: "./cache_hardhat",
  },
  test: {
    mocha: {
      parallel: true,
    },
  },
  networks: {
    default: {
      type: "edr-simulated",
      allowUnlimitedContractSize: true,
    },
  },
});
