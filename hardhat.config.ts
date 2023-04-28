import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import '@openzeppelin/hardhat-upgrades';
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";


const config: HardhatUserConfig = {
  defaultNetwork: "arbitrum",
  networks: {
    hardhat: {
      zksync: false,
    },
    goerli: {
      url: "https://eth-goerli.alchemyapi.io/v2/123abc123abc123abc123abc123abcde",
      accounts: [process.env.PKEY || "0000000000000000000000000000000000000000000000000000000000000000"],
      zksync: false,
    },
    zkTestnet: {
      url: "https://zksync2-testnet.zksync.dev", // https://goerli-api.zksync.io/jsrpc
      ethNetwork: "",
      chainId: 280,
      zksync: true,
      timeout: 10000
    },
    zk: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "",
      chainId: 324,
      zksync: true,
      verifyURL: 'https://zksync2-mainnet-explorer.zksync.io/contract_verification',
      timeout: 10000
    },
    arb: {
      url: "https://arb1.arbitrum.io/rpc",
      accounts: [process.env.PKEY || "0000000000000000000000000000000000000000000000000000000000000000"],
      chainId: 42161,
      zksync: false,
    },
    arbTestnet: {
      url: "https://goerli-rollup.arbitrum.io/rpc",
      accounts: [process.env.PKEY || "0000000000000000000000000000000000000000000000000000000000000000"],
      chainId: 421613,
      zksync: false,
    }
  },
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  zksolc: {
    version: "1.3.8",
    compilerSource: "binary",
    settings: {},
  },
  mocha: {
    timeout: 40000
  }
};

export default config;
