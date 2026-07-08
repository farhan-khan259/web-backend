/**
 * EWB Layer Tokens — Deploy All Three
 *
 * Deploys:
 *   L1T — EWBLayer1Token (NFT Liquidation Layer)
 *   L2T — EWBLayer2Token (Utility Liquidation Layer)
 *   L3T — EWBLayer3Token (Credit Extraction Layer)
 *
 * All three minted to SPV Treasury on deployment
 *
 * USAGE:
 *   npx hardhat run scripts/deploy-layer-tokens.js --network sepolia
 *   npx hardhat run scripts/deploy-layer-tokens.js --network mainnet
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();
  const isMainnet  = network.chainId === 1n;

  const USDC = isMainnet
    ? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    : "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

  const SPV = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   EWB LAYER TOKENS — DEPLOY ALL THREE   ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log("Network:", network.name);
  console.log("Deployer:", deployer.address);
  console.log("SPV Treasury:", SPV);
  console.log("USDC:", USDC);
  console.log();

  // ── LAYER 1 TOKEN ──────────────────────────────────────────
  console.log(">> Deploying L1T (NFT Liquidation Layer)...");
  const L1 = await ethers.getContractFactory("EWBLayer1Token");
  const l1 = await L1.deploy();
  await l1.waitForDeployment();
  const l1Address = await l1.getAddress();
  console.log("   L1T deployed:", l1Address);
  console.log("   Symbol: L1T — Total Supply: 10,000");
  console.log("   Layer 1 Value: 42,900 ETH / $89,961,300");

  // ── LAYER 2 TOKEN ──────────────────────────────────────────
  console.log("\n>> Deploying L2T (Utility Liquidation Layer)...");
  const L2 = await ethers.getContractFactory("EWBLayer2Token");
  const l2 = await L2.deploy(USDC);
  await l2.waitForDeployment();
  const l2Address = await l2.getAddress();
  console.log("   L2T deployed:", l2Address);
  console.log("   Symbol: L2T — Total Supply: 10,000");
  console.log("   Layer 2 Value: 27,992 ETH / $58,700,000");

  // ── LAYER 3 TOKEN ──────────────────────────────────────────
  console.log("\n>> Deploying L3T (Credit Extraction Layer)...");
  const L3 = await ethers.getContractFactory("EWBLayer3Token");
  const l3 = await L3.deploy(USDC);
  await l3.waitForDeployment();
  const l3Address = await l3.getAddress();
  console.log("   L3T deployed:", l3Address);
  console.log("   Symbol: L3T — Total Supply: 10,000");
  console.log("   Layer 3 Value: 6,391 ETH / $13,402,766");

  // ── CONNECT ORACLE TO ALL THREE TOKENS ───────────────────
  const ORACLE_ADDRESS = process.env.ORACLE_ADDRESS || "";

  if (ORACLE_ADDRESS && ORACLE_ADDRESS !== "") {
    console.log("\n>> Connecting TWAP oracle to all layer tokens...");

    await (await l1.connectOracle(ORACLE_ADDRESS)).wait();
    console.log("   L1T oracle connected ✓");

    await (await l2.connectOracle(ORACLE_ADDRESS)).wait();
    console.log("   L2T oracle connected ✓");

    await (await l3.connectOracle(ORACLE_ADDRESS)).wait();
    console.log("   L3T oracle connected ✓");

    // Verify live floor reads
    const [floorETH, floorUSD, isManual] = await l1.getLiveFloor();
    console.log(`   Live floor: ${ethers.formatEther(floorETH)} ETH / $${Number(floorUSD)/1e6} USD`);
    console.log(`   Source: ${isManual ? "MANUAL FLOOR" : "TWAP (30 day window)"}`);
  } else {
    console.log("\n⚠  ORACLE_ADDRESS not set — connect oracle manually after deployment:");
    console.log("   await l1.connectOracle('<ORACLE_ADDRESS>')");
    console.log("   await l2.connectOracle('<ORACLE_ADDRESS>')");
    console.log("   await l3.connectOracle('<ORACLE_ADDRESS>')");
  }

  // ── VERIFICATION COMMANDS ──────────────────────────────────
  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║         VERIFICATION COMMANDS           ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log(`npx hardhat verify --network ${network.name} ${l1Address}`);
  console.log(`npx hardhat verify --network ${network.name} ${l2Address} "${USDC}"`);
  console.log(`npx hardhat verify --network ${network.name} ${l3Address} "${USDC}"`);

  // ── SUMMARY ────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║           DEPLOYMENT SUMMARY            ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log(`L1T (Layer 1): ${l1Address}`);
  console.log(`L2T (Layer 2): ${l2Address}`);
  console.log(`L3T (Layer 3): ${l3Address}`);
  console.log(`\nAll tokens minted to SPV Treasury: ${SPV}`);
  console.log("\nSTACK TOTAL:");
  console.log("  Layer 1: $89,961,300 / 42,900 ETH");
  console.log("  Layer 2: $58,700,000 / 27,992 ETH");
  console.log("  Layer 3: $13,402,766 /  6,391 ETH");
  console.log("  TM IP:   $8,297,134  /  3,957 ETH");
  console.log("  ─────────────────────────────────");
  console.log("  TOTAL:   $170,361,200 / 81,240 ETH");

  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(
    `./deployments/layer-tokens-${network.name}-${Date.now()}.json`,
    JSON.stringify({
      network:  network.name,
      l1Token:  l1Address,
      l2Token:  l2Address,
      l3Token:  l3Address,
      spv:      SPV,
      usdc:     USDC,
    }, null, 2)
  );
  console.log("\nTWAP CONSOLE COMMANDS:");
  console.log("  await l1.getLiveFloor()          // live floor ETH/USD/isManual");
  console.log("  await l1.calculateLiveValue(amt) // live USD + ETH values");
  console.log("  await l2.getLiveFloor()          // live floor");
  console.log("  await l2.calculateLiveValue(amt) // live L2 value");
  console.log("  await l3.getLiveFloor()          // live floor");
  console.log("  await l3.calculateLiveBorrow(amt, tier) // live borrow capacity");
  console.log("  await l3.getLiveCreditCapacity() // total live vs static credit");
  console.log("\nDeployment record saved.");
}

main().then(() => process.exit(0)).catch(e => {
  console.error(e); process.exit(1);
});
