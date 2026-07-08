/**
 * EWB Protocol — Phased Sepolia Deployment (PHASE 1: Track A — the borrow loop)
 * ============================================================================
 * Deploys ONLY the credit / borrow-loop contracts, which all fit under the
 * EIP-170 24,576-byte code-size limit:
 *
 *     EWBGorillaOracle  →  EWBWhaleVault  →  EWBMintingRightsVault
 *
 * DEFERRED to a later phase (do NOT deploy here):
 *   • EWBDeltaNeutralVault — runtime bytecode is ~28.8 KB, OVER the EIP-170
 *     limit, so CREATE reverts on Sepolia/mainnet. Needs size reduction first.
 *   • EWBRevenueRouter / EWBCreditBridge — both are wired to DeltaNeutralVault
 *     (CreditBridge's constructor rejects a zero deltaVault), so they wait too.
 *
 * OWNERSHIP NOTE:
 *   EWBWhaleVault and EWBMintingRightsVault hard-code owner = BALLET_WALLET
 *   (0xc82A5959…). Their owner-only setup calls (setTokenTiers, lockMintingRights,
 *   borrowUSDC, …) MUST be sent from the Ballet wallet. This script only performs
 *   config it is actually authorised for (the oracle owner is the deployer); any
 *   WhaleVault owner steps are skipped with a printed reminder unless the deployer
 *   IS the Ballet wallet.
 *
 * Run: npx hardhat run scripts/deploy-sepolia-phased.js --network sepolia
 * Needs in .env: RPC_URL_SEPOLIA, PRIVATE_KEY (funded), ETHERSCAN_API_KEY (verify)
 */

const { ethers, network } = require("hardhat");
const fs = require("fs");

const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

async function main() {
  const [deployer] = await ethers.getSigners();
  const bal = await ethers.provider.getBalance(deployer.address);

  console.log("\n== EWB Sepolia Phase 1 — Track A (borrow loop) ==");
  console.log("Network :", network.name);
  console.log("Deployer:", deployer.address);
  console.log("Balance :", ethers.formatEther(bal), "ETH");
  if (bal === 0n) throw new Error("Deployer has 0 ETH — fund it before deploying.");

  const isBallet =
    deployer.address.toLowerCase() === BALLET_WALLET.toLowerCase();
  const addresses = {};

  // 1. Oracle — constructor(ewbPool, owner). No TWAP pool yet → zero.
  //    owner = deployer so this script can set the manual floor below.
  process.stdout.write("Deploying EWBGorillaOracle... ");
  const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy(ethers.ZeroAddress, deployer.address);
  await oracle.waitForDeployment();
  addresses.oracle = await oracle.getAddress();
  console.log("✓", addresses.oracle);

  // 2. WhaleVault — constructor(oracle). owner is hard-coded to BALLET_WALLET.
  process.stdout.write("Deploying EWBWhaleVault... ");
  const WhaleVault = await ethers.getContractFactory("EWBWhaleVault");
  const whaleVault = await WhaleVault.deploy(addresses.oracle);
  await whaleVault.waitForDeployment();
  addresses.whaleVault = await whaleVault.getAddress();
  console.log("✓", addresses.whaleVault);

  // 3. MintingRightsVault — constructor(whaleVault). owner hard-coded to BALLET.
  process.stdout.write("Deploying EWBMintingRightsVault... ");
  const MintingVault = await ethers.getContractFactory("EWBMintingRightsVault");
  const mintingVault = await MintingVault.deploy(addresses.whaleVault);
  await mintingVault.waitForDeployment();
  addresses.mintingVault = await mintingVault.getAddress();
  console.log("✓", addresses.mintingVault);

  // ── Config the deployer IS authorised for: the oracle manual floor ──────────
  console.log("\nConfiguring...");
  await (await oracle.setManualFloor(ethers.parseEther("4.29"))).wait();
  console.log("✓ Oracle manual floor set: 4.29 ETH/token");

  // ── Owner-only WhaleVault config — only if deployer is the Ballet wallet ─────
  if (isBallet) {
    const epicIds = Array.from({ length: 16 }, (_, i) => i + 1);
    await (await whaleVault.setTokenTiers(epicIds, epicIds.map(() => 0))).wait();
    console.log("✓ EPIC tiers set (token IDs 1-16)");
  } else {
    console.log(
      "⚠ Skipped WhaleVault.setTokenTiers — owner is the Ballet wallet " +
      `(${BALLET_WALLET}); run tier/lock/borrow steps from that key.`
    );
  }

  // ── Persist ─────────────────────────────────────────────────────────────────
  fs.mkdirSync("./deployments", { recursive: true });
  const outPath = `./deployments/${network.name}-phase1.json`;
  fs.writeFileSync(outPath, JSON.stringify(addresses, null, 2));
  console.log("\n✓ Addresses saved to", outPath);

  console.log("\n== PHASE 1 COMPLETE ==");
  Object.entries(addresses).forEach(([k, v]) => console.log(k.padEnd(14), v));

  console.log("\n-- Verify on Etherscan (needs ETHERSCAN_API_KEY) --");
  console.log(`npx hardhat verify --network ${network.name} ${addresses.oracle} ${ethers.ZeroAddress} ${deployer.address}`);
  console.log(`npx hardhat verify --network ${network.name} ${addresses.whaleVault} ${addresses.oracle}`);
  console.log(`npx hardhat verify --network ${network.name} ${addresses.mintingVault} ${addresses.whaleVault}`);

  console.log("\n-- Next (from the Ballet wallet) --");
  console.log("whaleVault.setTokenTiers([...], [...])");
  console.log("whaleVault.lockMintingRights([tokenIds], 'credit', 0)");
  console.log("mintingVault.borrowUSDC(lockId, [tokenIds], amount)  // USDC → Ballet wallet");
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error(e); process.exit(1); });
