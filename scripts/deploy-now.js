/**
 * EWB Whale Vault — Deploy Now
 * ==============================
 * Add your PRIVATE_KEY to .env then run:
 *
 * SEPOLIA TEST:
 *   npx hardhat run scripts/deploy-now.js --network sepolia
 *
 * MAINNET LIVE:
 *   npx hardhat run scripts/deploy-now.js --network mainnet
 *
 * After deploy — two commands to get USDC:
 *   npx hardhat run scripts/loop.js --network mainnet
 */

const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   EWB WHALE VAULT — DEPLOYING NOW       ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log("Ballet wallet:", deployer.address);
  console.log("Balance:", ethers.formatEther(
    await ethers.provider.getBalance(deployer.address)
  ), "ETH");
  console.log("Network:", (await ethers.provider.getNetwork()).name);

  const deployed = {};

  // 1. Oracle
  process.stdout.write("\n[1/6] EWBGorillaOracle... ");
  const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy(ethers.ZeroAddress, deployer.address);
  await oracle.waitForDeployment();
  deployed.oracle = await oracle.getAddress();
  console.log("✓", deployed.oracle);

  // Set manual floor — 4.29 ETH (live market floor)
  await (await oracle.setValuationBand(ethers.parseEther("4.29"))).wait();
  await (await oracle.setManualFloorMaxAge(1800)).wait();
  console.log("   ✓ Valuation band set: 4.29 ETH (live floor)");

  // 2. WhaleVault
  process.stdout.write("[2/6] EWBWhaleVault... ");
  const WhaleVault = await ethers.getContractFactory("EWBWhaleVault");
  const whaleVault = await WhaleVault.deploy(deployed.oracle);
  await whaleVault.waitForDeployment();
  deployed.whaleVault = await whaleVault.getAddress();
  console.log("✓", deployed.whaleVault);

  // Set token tiers — EPIC 1-16
  const epicIds = Array.from({ length: 16 }, (_, i) => i + 1);
  await (await whaleVault.setTokenTiers(epicIds, epicIds.map(() => 0))).wait();
  console.log("   ✓ EPIC tiers set (token IDs 1-16)");

  // 3. DeltaNeutralVault
  process.stdout.write("[3/6] EWBDeltaNeutralVault... ");
  const DeltaVault = await ethers.getContractFactory("EWBDeltaNeutralVault");
  const deltaVault = await DeltaVault.deploy(deployer.address, deployer.address);
  await deltaVault.waitForDeployment();
  deployed.deltaVault = await deltaVault.getAddress();
  console.log("✓", deployed.deltaVault);

  // 4. CreditBridge
  process.stdout.write("[4/6] EWBCreditBridge... ");
  const Bridge = await ethers.getContractFactory("EWBCreditBridge");
  const bridge = await Bridge.deploy(deployed.whaleVault, deployed.deltaVault);
  await bridge.waitForDeployment();
  deployed.creditBridge = await bridge.getAddress();
  console.log("✓", deployed.creditBridge);

  // Wire WhaleVault → CreditBridge
  await (await whaleVault.setCreditBridge(deployed.creditBridge)).wait();
  console.log("   ✓ WhaleVault → CreditBridge wired");

  // 5. MintingRightsVault
  process.stdout.write("[5/6] EWBMintingRightsVault... ");
  const MintingVault = await ethers.getContractFactory("EWBMintingRightsVault");
  const mintingVault = await MintingVault.deploy(deployed.whaleVault);
  await mintingVault.waitForDeployment();
  deployed.mintingVault = await mintingVault.getAddress();
  console.log("✓", deployed.mintingVault);

  await (await mintingVault.setDeltaVault(deployed.deltaVault)).wait();
  console.log("   ✓ MintingVault → DeltaVault wired");

  // 6. RevenueRouter
  process.stdout.write("[6/6] EWBRevenueRouter... ");
  const Router = await ethers.getContractFactory("EWBRevenueRouter");
  const router = await Router.deploy();
  await router.waitForDeployment();
  deployed.revenueRouter = await router.getAddress();
  console.log("✓", deployed.revenueRouter);

  // Save addresses
  const network = (await ethers.provider.getNetwork()).name;
  const outPath = `./deployments/${network}.json`;
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(deployed, null, 2));

  // Update .env with deployed addresses
  let env = fs.readFileSync(".env", "utf8");
  env = env.replace("WHALE_VAULT_ADDRESS=",    `WHALE_VAULT_ADDRESS=${deployed.whaleVault}`);
  env = env.replace("MINTING_VAULT_ADDRESS=",  `MINTING_VAULT_ADDRESS=${deployed.mintingVault}`);
  env = env.replace("CREDIT_BRIDGE_ADDRESS=",  `CREDIT_BRIDGE_ADDRESS=${deployed.creditBridge}`);
  env = env.replace("DELTA_VAULT_ADDRESS=",    `DELTA_VAULT_ADDRESS=${deployed.deltaVault}`);
  env = env.replace("REVENUE_ROUTER_ADDRESS=", `REVENUE_ROUTER_ADDRESS=${deployed.revenueRouter}`);
  env = env.replace("ORACLE_ADDRESS=",         `ORACLE_ADDRESS=${deployed.oracle}`);
  fs.writeFileSync(".env", env);

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   DEPLOYED ✓                             ║");
  console.log("╚══════════════════════════════════════════╝");
  Object.entries(deployed).forEach(([k, v]) => {
    console.log(k.padEnd(16), v);
  });
  console.log("\nAddresses saved to:", outPath);
  console.log(".env updated automatically");

  console.log("\n── NEXT: GET USDC ──────────────────────────");
  console.log("npx hardhat run scripts/loop.js --network", network);
}

main()
  .then(() => process.exit(0))
  .catch(e => { console.error(e); process.exit(1); });
