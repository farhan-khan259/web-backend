const { JsonRpcProvider } = require("ethers");

async function main() {
  const rpcUrl = process.env.RPC_URL_SEPOLIA;
  if (!rpcUrl) {
    throw new Error("RPC_URL_SEPOLIA is not set");
  }

  const provider = new JsonRpcProvider(rpcUrl);
  const blockNumber = await provider.getBlockNumber();
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ✅ Successfully connected to Sepolia via Alchemy.`);
  console.log(`Latest block number: ${blockNumber}`);
  console.log("Milestone 1 connectivity check passed.");
}

main().catch((error) => {
  console.error("❌ Connection failed:", error.message);
  process.exitCode = 1;
});
