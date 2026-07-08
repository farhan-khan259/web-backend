/**
 * EWB Protocol — FULL Sepolia Deployment (all 6 core contracts)
 * ============================================================================
 * Wayne Fyffe · Exposed Walls (EWB)
 *
 * Deploys, in one shot:
 *   1. EWBGorillaOracle      ctor(ewbPool, owner)
 *   2. EWBWhaleVault         ctor(oracle)              owner = BALLET_WALLET (const)
 *   3. EWBMintingRightsVault ctor(whaleVault)          owner = BALLET_WALLET (const)
 *   4. EWBRevenueRouter      ctor(deltaVault, minting) owner = BALLET_WALLET (const)  ┐ circular
 *   5. EWBDeltaNeutralVault  ctor(safe, cold, router)  owner = safeMultisig          ┘ pair
 *   6. EWBCreditBridge       ctor(whaleVault, deltaVault)
 *
 * ── CIRCULAR IMMUTABLE DEPENDENCY (resolved here) ───────────────────────────
 *   EWBDeltaNeutralVault.revenueRouter is `immutable`  → needs the router address
 *                                                         at construction.
 *   EWBRevenueRouter.deltaVault       is `immutable`  → needs the vault address
 *                                                         at construction.
 *   Both constructors `require(!= address(0))`, so neither can be deployed with a
 *   placeholder and patched later.
 *
 *   FIX (no contract changes): a contract's CREATE address depends only on
 *   (deployer, nonce) — NOT on its constructor args. So we pre-compute the
 *   address EWBDeltaNeutralVault WILL occupy at the deployer's *next+1* nonce,
 *   feed that predicted address into the RevenueRouter constructor, then deploy
 *   the vault immediately after so it lands exactly at the predicted address.
 *   We assert predicted == actual before continuing.
 *
 * ── OWNERSHIP REALITY (important) ───────────────────────────────────────────
 *   EWBWhaleVault, EWBMintingRightsVault and EWBRevenueRouter hard-code
 *   owner = BALLET_WALLET (0xc82A59…D46cf). Anyone can DEPLOY them, but every
 *   owner-only call (setTokenTiers, setCreditBridge, setDeltaVault, lock/borrow)
 *   MUST be sent from the Ballet wallet. This script performs only the wiring it
 *   is authorised for; Ballet-owner steps are SKIPPED with a printed reminder
 *   unless the deployer IS the Ballet wallet.
 *
 * Run:   npx hardhat run scripts/deploy-sepolia.js --network sepolia
 * Needs: .env RPC_URL_SEPOLIA, PRIVATE_KEY (funded), ETHERSCAN_API_KEY (verify)
 * Optional .env: SAFE_MULTISIG, COLD_WALLET (default: deployer on testnet)
 */

const { ethers, network } = require("hardhat");
const fs = require("fs");

const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

async function main() {
  const [deployer] = await ethers.getSigners();
  const bal = await ethers.provider.getBalance(deployer.address);

  console.log("\n== EWB Sepolia — FULL DEPLOY (6 contracts) ==");
  console.log("Network :", network.name);
  console.log("Deployer:", deployer.address);
  console.log("Balance :", ethers.formatEther(bal), "ETH");
  if (bal === 0n && network.name !== "hardhat") {
    throw new Error("Deployer has 0 ETH — fund it before deploying.");
  }

  const isBallet = deployer.address.toLowerCase() === BALLET_WALLET.toLowerCase();
  // DeltaVault is operable by safeMultisig (its ctor sets owner = safeMultisig),
  // so on testnet default it to the deployer so Track B is exercisable.
  const safeMultisig = process.env.SAFE_MULTISIG || deployer.address;
  const coldWallet   = process.env.COLD_WALLET   || deployer.address;

  const A = {}; // deployed addresses

  // ── 1. Oracle — owner = deployer so this script can set the manual floor ────
  process.stdout.write("1/6 EWBGorillaOracle... ");
  const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy(ethers.ZeroAddress, deployer.address);
  await oracle.waitForDeployment();
  A.oracle = await oracle.getAddress();
  console.log("✓", A.oracle);

  // ── 2. WhaleVault ───────────────────────────────────────────────────────────
  process.stdout.write("2/6 EWBWhaleVault... ");
  const WhaleVault = await ethers.getContractFactory("EWBWhaleVault");
  const whaleVault = await WhaleVault.deploy(A.oracle);
  await whaleVault.waitForDeployment();
  A.whaleVault = await whaleVault.getAddress();
  console.log("✓", A.whaleVault);

  // ── 3. MintingRightsVault ─────────────────────────────────────────────────
  process.stdout.write("3/6 EWBMintingRightsVault... ");
  const MintingVault = await ethers.getContractFactory("EWBMintingRightsVault");
  const mintingVault = await MintingVault.deploy(A.whaleVault);
  await mintingVault.waitForDeployment();
  A.mintingVault = await mintingVault.getAddress();
  console.log("✓", A.mintingVault);

  // ── 4 + 5. RevenueRouter ⇄ DeltaVault (circular immutable pair) ─────────────
  // Pre-compute the DeltaVault address at the deployer's (next + 1) nonce.
  const nonceNow = await ethers.provider.getTransactionCount(deployer.address, "pending");
  const predictedDelta = ethers.getCreateAddress({
    from: deployer.address,
    nonce: nonceNow + 1, // router consumes `nonceNow`, vault consumes `nonceNow + 1`
  });
  console.log("   ↳ predicted DeltaVault @ nonce", nonceNow + 1, "=", predictedDelta);

  process.stdout.write("4/6 EWBRevenueRouter... ");
  const RevenueRouter = await ethers.getContractFactory("EWBRevenueRouter");
  const revenueRouter = await RevenueRouter.deploy(predictedDelta, A.mintingVault);
  await revenueRouter.waitForDeployment();
  A.revenueRouter = await revenueRouter.getAddress();
  console.log("✓", A.revenueRouter);

  process.stdout.write("5/6 EWBDeltaNeutralVault... ");
  const DeltaVault = await ethers.getContractFactory("EWBDeltaNeutralVault");
  const deltaVault = await DeltaVault.deploy(safeMultisig, coldWallet, A.revenueRouter);
  await deltaVault.waitForDeployment();
  A.deltaVault = await deltaVault.getAddress();
  console.log("✓", A.deltaVault);

  // Assert the CREATE-nonce prediction held — otherwise the router points at the
  // wrong vault and the whole wiring is silently broken.
  if (A.deltaVault.toLowerCase() !== predictedDelta.toLowerCase()) {
    throw new Error(
      `CREATE-nonce prediction FAILED: predicted ${predictedDelta} but vault ` +
      `landed at ${A.deltaVault}. A stray deployer tx changed the nonce — rerun.`
    );
  }
  console.log("   ↳ prediction confirmed: RevenueRouter ⇄ DeltaVault linked ✓");

  // ── 6. CreditBridge ─────────────────────────────────────────────────────────
  process.stdout.write("6/6 EWBCreditBridge... ");
  const CreditBridge = await ethers.getContractFactory("EWBCreditBridge");
  const creditBridge = await CreditBridge.deploy(A.whaleVault, A.deltaVault);
  await creditBridge.waitForDeployment();
  A.creditBridge = await creditBridge.getAddress();
  console.log("✓", A.creditBridge);

  // ── Config the deployer IS authorised for (oracle owner = deployer) ─────────
  console.log("\nConfiguring (deployer-authorised)...");
  await (await oracle.setManualFloor(ethers.parseEther("4.29"))).wait();
  console.log("✓ Oracle manual floor set: 4.29 ETH/token");

  // ── Owner-only wiring — only if deployer is the Ballet wallet ───────────────
  if (isBallet) {
    await (await whaleVault.setCreditBridge(A.creditBridge)).wait();
    console.log("✓ WhaleVault → CreditBridge wired");
    await (await whaleVault.setDeltaVault(A.deltaVault)).wait();
    console.log("✓ WhaleVault → DeltaVault wired");
    await (await mintingVault.setDeltaVault(A.deltaVault)).wait();
    console.log("✓ MintingVault → DeltaVault wired");
  } else {
    console.log(
      "\n⚠ Ballet-owner wiring SKIPPED (deployer is not the Ballet wallet).\n" +
      "  Run these THREE calls from the Ballet wallet (0xc82A59…D46cf):\n" +
      `    whaleVault.setCreditBridge(${A.creditBridge})\n` +
      `    whaleVault.setDeltaVault(${A.deltaVault})\n` +
      `    mintingVault.setDeltaVault(${A.deltaVault})`
    );
  }

  // ── Persist ─────────────────────────────────────────────────────────────────
  fs.mkdirSync("./deployments", { recursive: true });
  const outPath = `./deployments/${network.name}.json`;
  fs.writeFileSync(outPath, JSON.stringify(A, null, 2));
  console.log("\n✓ Addresses saved to", outPath);

  console.log("\n== DEPLOYMENT COMPLETE ==");
  Object.entries(A).forEach(([k, v]) => console.log(k.padEnd(14), v));

  // ── Verify commands (constructor args match the REAL constructors) ──────────
  console.log("\n-- Verify on Etherscan (needs ETHERSCAN_API_KEY) --");
  const n = network.name;
  console.log(`npx hardhat verify --network ${n} ${A.oracle} ${ethers.ZeroAddress} ${deployer.address}`);
  console.log(`npx hardhat verify --network ${n} ${A.whaleVault} ${A.oracle}`);
  console.log(`npx hardhat verify --network ${n} ${A.mintingVault} ${A.whaleVault}`);
  console.log(`npx hardhat verify --network ${n} ${A.revenueRouter} ${A.deltaVault} ${A.mintingVault}`);
  console.log(`npx hardhat verify --network ${n} ${A.deltaVault} ${safeMultisig} ${coldWallet} ${A.revenueRouter}`);
  console.log(`npx hardhat verify --network ${n} ${A.creditBridge} ${A.whaleVault} ${A.deltaVault}`);

  console.log("\n-- Borrow loop (run from the Ballet wallet) --");
  console.log("PRIVATE_KEY=<ballet_key> npx hardhat run scripts/run-borrow-loop-sepolia.js --network sepolia");
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error(e); process.exit(1); });
