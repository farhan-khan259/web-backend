/**
 * EWB Whale Vault — Minimum Deploy
 * 3 contracts. ~$30 gas. USDC in wallet same day.
 *
 * Run: npx hardhat run scripts/deploy-minimum.js --network mainnet
 *
 * Needs in .env:
 *   PRIVATE_KEY=your_ballet_wallet_private_key
 *   RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
 */

const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   EWB WHALE VAULT — MINIMUM DEPLOY      ║");
  console.log("║   3 contracts · ~$30 gas · USDC today   ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log("Ballet wallet:", deployer.address);
  console.log("ETH balance: ", ethers.formatEther(
    await ethers.provider.getBalance(deployer.address)
  ), "ETH");

  const addresses = {};

  // ── 1. Oracle ────────────────────────────────────────────────
  process.stdout.write("\n[1/3] Deploying EWBGorillaOracle... ");
  const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy(
    ethers.ZeroAddress,  // no TWAP pool yet
    deployer.address     // owner
  );
  await oracle.waitForDeployment();
  addresses.oracle = await oracle.getAddress();
  console.log("✓", addresses.oracle);

  // Set manual floor price — 4.29 ETH per token
  await (await oracle.setManualFloor(ethers.parseEther("4.29"))).wait();
  await (await oracle.setManualFloorMaxAge(1800)).wait(); // 30 min
  console.log("   ✓ Floor price set: 4.29 ETH");

  // ── 2. WhaleVault ────────────────────────────────────────────
  process.stdout.write("\n[2/3] Deploying EWBWhaleVault... ");
  const WhaleVault = await ethers.getContractFactory("EWBWhaleVault");
  const whaleVault = await WhaleVault.deploy(addresses.oracle);
  await whaleVault.waitForDeployment();
  addresses.whaleVault = await whaleVault.getAddress();
  console.log("✓", addresses.whaleVault);

  // Set token tiers — EPIC tokens 1-16
  const epicIds = Array.from({ length: 16 }, (_, i) => i + 1);
  await (await whaleVault.setTokenTiers(
    epicIds,
    epicIds.map(() => 0) // TIER_EPIC_ID = 0
  )).wait();
  console.log("   ✓ EPIC tiers set (token IDs 1-16)");

  // Lock tiers permanently
  await (await whaleVault.lockTiers()).wait();
  console.log("   ✓ Tiers locked permanently");

  // ── 3. MintingRightsVault ────────────────────────────────────
  process.stdout.write("\n[3/3] Deploying EWBMintingRightsVault... ");
  const MintingVault = await ethers.getContractFactory("EWBMintingRightsVault");
  const mintingVault = await MintingVault.deploy(addresses.whaleVault);
  await mintingVault.waitForDeployment();
  addresses.mintingVault = await mintingVault.getAddress();
  console.log("✓", addresses.mintingVault);

  // ── Save addresses ───────────────────────────────────────────
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(
    "./deployments/mainnet-minimum.json",
    JSON.stringify(addresses, null, 2)
  );

  // ── Summary ──────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   DEPLOYED. READY TO BORROW.             ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log("Oracle:        ", addresses.oracle);
  console.log("WhaleVault:    ", addresses.whaleVault);
  console.log("MintingVault:  ", addresses.mintingVault);

  console.log("\n── GET USDC NOW ────────────────────────────");
  console.log("1. lockMintingRights([1,2,3,...16], 'credit', 0)");
  console.log("2. borrowUSDC(lockId, tokenIds, amount)");
  console.log("3. USDC in Ballet wallet instantly");
  console.log("\nAddresses saved to: deployments/mainnet-minimum.json");
}

main()
  .then(() => process.exit(0))
  .catch(e => { console.error(e); process.exit(1); });
