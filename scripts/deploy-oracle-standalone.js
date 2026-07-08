const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

async function main() {
  // Load the contract artifact
  const artifactPath = path.join(__dirname, "../artifacts/contracts/EWBGorillaOracle.sol/EWBGorillaOracle.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth-mainnet.g.alchemy.com/v2/DaXupNusiArJ84o7YqJUk";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;

  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set in .env");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("Deploying with account:", wallet.address);

  const balance = await provider.getBalance(wallet.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const contract = await factory.deploy("0x0000000000000000000000000000000000000000", BALLET);
  await contract.waitForDeployment();
  console.log("Oracle deployed to:", contract.target);
}

main().catch(console.error);
