const ethers = require("ethers");
const fs = require("fs");
const path = require("path");

async function main() {
  const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth-mainnet.g.alchemy.com/v2/DaXupNusiArJ84o7YqJUk";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set in .env");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("Using wallet:", wallet.address);

  const contractAddress = "0x0c06d6a17eb208a9bc7bd698eb6f22379209e3a4";
  const abi = [
    "function pause() external",
    "function setPaused(bool) external",
    "function paused() view returns (bool)"
  ];
  const contract = new ethers.Contract(contractAddress, abi, wallet);

  console.log("Current paused status:", await contract.paused());

  console.log("Pausing contract...");
  try {
    const tx = await contract.pause();
    await tx.wait();
    console.log("✅ Pause successful. Tx hash:", tx.hash);
  } catch (e) {
    console.log("pause() failed, trying setPaused(true)...");
    try {
      const tx = await contract.setPaused(true);
      await tx.wait();
      console.log("✅ setPaused(true) successful. Tx hash:", tx.hash);
    } catch (err) {
      console.error("Both methods failed:", err.message);
    }
  }

  console.log("New paused status:", await contract.paused());
}
main().catch(console.error);
