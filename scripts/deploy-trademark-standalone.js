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

  const artifactPath = path.join(__dirname, "../artifacts/contracts/EWBTrademarkBridge.sol/EWBTrademarkBridge.json");
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const contract = await factory.deploy();
  await contract.waitForDeployment();
  console.log("EWBTrademarkBridge deployed to:", contract.target);
}

main().catch(console.error);
