const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

async function main() {
  const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth-mainnet.g.alchemy.com/v2/DaXupNusiArJ84o7YqJUk";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("Deployer:", wallet.address);

  const artifactPath = path.join(__dirname, "../artifacts/contracts/EWBDevPayment.sol/EWBDevPayment.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const contract = await factory.deploy(BALLET, wallet.address, USDC);
  await contract.waitForDeployment();
  console.log("EWBDevPayment deployed to:", contract.target);
}
main().catch(console.error);
