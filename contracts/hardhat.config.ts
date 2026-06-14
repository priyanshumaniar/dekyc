import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL ?? "";
const RAW_KEY = (process.env.DEPLOYER_PRIVATE_KEY ?? "").trim();
// Hardhat/ethers requires a 0x-prefixed private key; normalise if missing.
const DEPLOYER_PRIVATE_KEY = RAW_KEY
  ? RAW_KEY.startsWith("0x")
    ? RAW_KEY
    : `0x${RAW_KEY}`
  : "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY ?? "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      // OpenZeppelin v5.1+ uses the `mcopy` opcode → requires Cancun.
      // Sepolia is post-Dencun, so Cancun bytecode deploys fine.
      evmVersion: "cancun",
    },
  },
  networks: {
    // Local in-process network used by `hardhat test`.
    hardhat: {},
    // The ONLY public network this project targets. No mainnet anywhere.
    sepolia: {
      url: SEPOLIA_RPC_URL,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
      chainId: 11155111,
      // Explicit gas settings prevent the tx from stalling in the mempool.
      // 20 gwei max fee + 2 gwei priority tip is well above Sepolia's floor.
      gasPrice: "auto",
      gas: "auto",
      maxFeePerGas: 20_000_000_000,       // 20 gwei
      maxPriorityFeePerGas: 2_000_000_000, // 2 gwei
    },
  },
  etherscan: {
    // Etherscan V2 uses a single unified API key across networks.
    apiKey: ETHERSCAN_API_KEY,
  },
  sourcify: {
    enabled: false,
  },
};

export default config;
