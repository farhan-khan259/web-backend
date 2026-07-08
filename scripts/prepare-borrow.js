const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

async function main() {
  const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth-mainnet.g.alchemy.com/v2/DaXupNusiArJ84o7YqJUk";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("Preparing borrow with account:", wallet.address);

  const WHALE_ADDR = "0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529";
  const MINTING_ADDR = "0x2E4C26B33Ae96823e1C37cDbCB28dF0169A2738D";

  const whaleArtifact = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../artifacts/contracts/EWBWhaleVault.sol/EWBWhaleVault.json"), "utf8"
  ));
  const mintingArtifact = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../artifacts/contracts/EWBMintingRightsVault.sol/EWBMintingRightsVault.json"), "utf8"
  ));

  const whale = new ethers.Contract(WHALE_ADDR, whaleArtifact.abi, wallet);
  const minting = new ethers.Contract(MINTING_ADDR, mintingArtifact.abi, wallet);

  // Set token tier (EPIC = tier 0, 315 ETH floor)
  console.log("Setting token tier...");
  const tokenIds = [1];
  const tiers = [0];
  const tx1 = await whale.setTokenTiers(tokenIds, tiers);
  await tx1.wait();
  console.log("✅ Token tier set");

  // Lock minting rights
  console.log("Locking minting rights...");
  const faceValueETH = ethers.parseEther("315");
  const faceValueUSD = 567000000000; // 315 ETH * 1800 USD = 567,000 USDC (6 decimals)
  const tx2 = await whale.lockMintingRights(tokenIds, faceValueETH, faceValueUSD, "borrow-250k-test", 0);
  const receipt2 = await tx2.wait();

  // Find lockId from event
  const event = receipt2.logs.find(log => {
    try {
      const parsed = whale.interface.parseLog(log);
      return parsed && parsed.name === "MintingRightsLocked";
    } catch { return false; }
  });
  const lockId = event ? whale.interface.parseLog(event).args[0] : 1;
  console.log("✅ Minting rights locked with lockId:", lockId.toString());

  // Prepare borrow calldata
  const borrowAmount = 250000000000; // 250,000 USDC (6 decimals)
  const data = minting.interface.encodeFunctionData("borrowUSDC", [lockId, borrowAmount]);

  console.log("\n===== WAYNE'S BORROW INSTRUCTIONS =====");
  console.log("Contract:", MINTING_ADDR);
  console.log("Function: borrowUSDC");
  console.log("lockId:", lockId.toString());
  console.log("amount:", borrowAmount);
  console.log("Calldata:", data);
  console.log("\nWayne should connect his Ballet wallet to Etherscan and call borrowUSDC with these parameters.");
}

main().catch(console.error);
