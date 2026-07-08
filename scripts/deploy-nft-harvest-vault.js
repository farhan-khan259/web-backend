// scripts/deploy-nft-harvest-vault.js
// Deploy EWBNFTHarvestVault — ERC-721 → ERC-20 Harvest Engine
//
// Prerequisites (must already be deployed):
//   - EWBWhaleVault
//   - EWBGorillaOracle
//   - EWBLayer1Token (or chosen harvest ERC-20)
//
// Run:
//   npx hardhat run scripts/deploy-nft-harvest-vault.js --network sepolia

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // ── Config — fill these before deploying ────────────────────
  const SAFE_MULTISIG   = process.env.SAFE_MULTISIG;
  const COLD_WALLET     = process.env.COLD_WALLET;
  const WHALE_VAULT     = process.env.WHALE_VAULT;    // EWBWhaleVault address
  const ORACLE          = process.env.ORACLE;          // EWBGorillaOracle address
  const HARVEST_TOKEN   = process.env.HARVEST_TOKEN;  // ERC-20 token for payouts (e.g. L1T)
  const HARVEST_RATE_BPS = 1000; // 10% of face value per harvest cycle

  if (!SAFE_MULTISIG || !COLD_WALLET || !WHALE_VAULT || !ORACLE || !HARVEST_TOKEN) {
    throw new Error(
      "Missing env vars. Set: SAFE_MULTISIG, COLD_WALLET, WHALE_VAULT, ORACLE, HARVEST_TOKEN"
    );
  }

  console.log("\nDeploying EWBNFTHarvestVault...");
  console.log("  safeMultisig  :", SAFE_MULTISIG);
  console.log("  coldWallet    :", COLD_WALLET);
  console.log("  whaleVault    :", WHALE_VAULT);
  console.log("  oracle        :", ORACLE);
  console.log("  harvestToken  :", HARVEST_TOKEN);
  console.log("  harvestRateBps:", HARVEST_RATE_BPS, "(10%)");

  const Factory = await ethers.getContractFactory("EWBNFTHarvestVault");
  const vault = await Factory.deploy(
    SAFE_MULTISIG,
    COLD_WALLET,
    WHALE_VAULT,
    ORACLE,
    HARVEST_TOKEN,
    HARVEST_RATE_BPS
  );
  await vault.waitForDeployment();

  const address = await vault.getAddress();
  console.log("\n✅ EWBNFTHarvestVault deployed:", address);

  console.log("\n── Post-deploy checklist ──────────────────────────────");
  console.log("1. Fund reserve: multisig calls fundReserve(amount) after");
  console.log("   approving this vault on the harvest ERC-20 contract.");
  console.log("2. Verify on Etherscan:");
  console.log(`   npx hardhat verify --network sepolia ${address} \\`);
  console.log(`     "${SAFE_MULTISIG}" "${COLD_WALLET}" "${WHALE_VAULT}" \\`);
  console.log(`     "${ORACLE}" "${HARVEST_TOKEN}" ${HARVEST_RATE_BPS}`);
  console.log("3. NFT holders must call:");
  console.log("   EWB_CONTRACT.setApprovalForAll(vault, true) before lockNFTs()");
  console.log("4. WhaleVault harvest tokens must be issued to holders");
  console.log("   before harvestERC20() can be called.");

  return address;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
