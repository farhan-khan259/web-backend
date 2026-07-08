/**
 * EWB Revenue Router — Deploy Script
 *
 * Deploys EWBRevenueRouter and connects it to the
 * three layer tokens for income distribution.
 *
 * USAGE:
 *   npx hardhat run scripts/deploy-revenue-router.js --network sepolia
 *   npx hardhat run scripts/deploy-revenue-router.js --network mainnet
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();
  const isMainnet  = network.chainId === 1n;

  // ── ADDRESSES ──────────────────────────────────────────────
  const L1T_ADDRESS = process.env.L1T_ADDRESS || "";
  const L2T_ADDRESS = process.env.L2T_ADDRESS || "";
  const L3T_ADDRESS = process.env.L3T_ADDRESS || "";

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║      EWB REVENUE ROUTER — DEPLOY        ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log("Network:  ", network.name);
  console.log("Deployer: ", deployer.address);
  console.log("L1T:      ", L1T_ADDRESS || "NOT SET");
  console.log("L2T:      ", L2T_ADDRESS || "NOT SET");
  console.log("L3T:      ", L3T_ADDRESS || "NOT SET");
  console.log();

  // ── DEPLOY ─────────────────────────────────────────────────
  console.log(">> Deploying EWBRevenueRouter...");
  const Router = await ethers.getContractFactory("EWBRevenueRouter");
  const router = await Router.deploy();
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("   Router deployed:", routerAddress);

  // ── CONNECT L3T TO ROUTER ───────────────────────────────────
  // L3T needs to know the router address for yield distribution
  if (L3T_ADDRESS) {
    console.log("\n>> Connecting router to L3T...");
    const l3t = await ethers.getContractAt("EWBLayer3Token", L3T_ADDRESS);
    await (await l3t.setRevenueRouter(routerAddress)).wait();
    console.log("   L3T revenue router set ✓");
  } else {
    console.log("\n⚠  L3T_ADDRESS not set — connect manually:");
    console.log("   await l3t.setRevenueRouter('" + routerAddress + "')");
  }

  // ── VERIFY INITIAL STATE ────────────────────────────────────
  const [lp, steth, dydx, total] = await router.getAnnualEstimates();
  console.log("\n>> Annual income estimates:");
  console.log("   LP Fees:     $" + (Number(lp) / 1e6).toLocaleString());
  console.log("   stETH Yield: $" + (Number(steth) / 1e6).toLocaleString());
  console.log("   dYdX:        $" + (Number(dydx) / 1e6).toLocaleString());
  console.log("   Total:       $" + (Number(total) / 1e6).toLocaleString() + "/yr");

  // ── VERIFICATION ────────────────────────────────────────────
  console.log("\nVERIFY:");
  console.log(`npx hardhat verify --network ${network.name} ${routerAddress}`);

  // ── CONSOLE COMMANDS ────────────────────────────────────────
  console.log("\nCONSOLE COMMANDS:");
  console.log(`const router = await ethers.getContractAt("EWBRevenueRouter", "${routerAddress}")`);
  console.log("await router.getAnnualEstimates()");
  console.log("await router.getTotalIncome()");
  console.log("await router.routeLPFees('<TOKEN>', amount)");
  console.log("await router.recordStETHYield(amount)");
  console.log("await router.routeDyDxIncome('<TOKEN>', amount)");
  console.log("await router.routeToTBA('<TOKEN>', '<TBA_ADDR>', amount)");

  // ── SAVE RECORD ─────────────────────────────────────────────
  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(
    `./deployments/revenue-router-${network.name}-${Date.now()}.json`,
    JSON.stringify({
      network:       network.name,
      router:        routerAddress,
      owner:         deployer.address,
      l1Token:       L1T_ADDRESS,
      l2Token:       L2T_ADDRESS,
      l3Token:       L3T_ADDRESS,
      deployedAt:    new Date().toISOString(),
    }, null, 2)
  );
  console.log("\nDeployment record saved.");
}

main().then(() => process.exit(0)).catch(e => {
  console.error(e); process.exit(1);
});
