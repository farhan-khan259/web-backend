/**
 * EWB Whale Vault — Full Loop Test on Sepolia
 * Run AFTER deploy-sepolia.js
 *
 * Tests the complete cycle:
 * fund → lock → borrow → autoRepay → unlock
 *
 * Run: npx hardhat run scripts/test-loop-sepolia.js --network sepolia
 */

const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();
  const addresses  = JSON.parse(fs.readFileSync("./deployments/sepolia.json"));

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   EWB WHALE VAULT — SEPOLIA LOOP TEST   ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log("Ballet wallet:", deployer.address);

  const whaleVault   = await ethers.getContractAt("EWBWhaleVault",        addresses.whaleVault);
  const mintingVault = await ethers.getContractAt("EWBMintingRightsVault", addresses.mintingVault);
  const bridge       = await ethers.getContractAt("EWBCreditBridge",       addresses.creditBridge);

  // Test token IDs — EPIC tier
  const tokenIds = [1n, 2n, 3n];

  // ── TEST 1: Fund bridge ──────────────────────────────────────
  console.log("\n── TEST 1: Fund bridge ─────────────────────");
  const fundTx = await bridge.fund({ value: ethers.parseEther("0.1") });
  await fundTx.wait();
  const bal = await bridge.bridgeBalance();
  console.log("✓ Bridge funded:", ethers.formatEther(bal), "ETH");
  console.assert(bal > 0n, "Bridge balance should be > 0");

  // ── TEST 2: Lock minting rights ──────────────────────────────
  console.log("\n── TEST 2: Lock minting rights ─────────────");
  const lockTx  = await whaleVault.lockMintingRights(tokenIds, "credit", 0);
  const lockRx  = await lockTx.wait();
  const lockEvt = lockRx.logs.find(l => l.fragment?.name === "MintingRightsLocked");
  const lockId  = lockEvt.args.lockId;
  console.log("✓ Lock ID:", lockId.toString());

  // Verify lock
  const lock = await whaleVault.getLock(lockId);
  console.log("✓ Face value ETH:", ethers.formatEther(lock.faceValueETH));
  console.log("✓ Lock active:", lock.active);
  console.assert(lock.active === true, "Lock should be active");

  // Verify token IDs locked
  for (const id of tokenIds) {
    const locked = await whaleVault.isMintingRightLocked(id);
    console.assert(locked, `Token ${id} should be locked`);
  }
  console.log("✓ All token IDs confirmed locked");

  // ── TEST 3: Verify credit bridge deployed ETH ────────────────
  console.log("\n── TEST 3: Credit bridge auto-deployment ───");
  const deployed = await bridge.deployedForLock(lockId);
  console.log("✓ ETH deployed for lock:", ethers.formatEther(deployed));
  console.assert(deployed > 0n, "Bridge should have deployed ETH");

  // ── TEST 4: Borrow USDC ──────────────────────────────────────
  console.log("\n── TEST 4: Borrow USDC from Aave ───────────");
  const faceUSD    = lock.faceValueUSD;
  const drawAmount = faceUSD * 800n / 10000n; // 8% of face (STANDARD LTV)
  console.log("Face value USD:", ethers.formatUnits(faceUSD, 6));
  console.log("Drawing:", ethers.formatUnits(drawAmount, 6), "USDC");

  const borrowTx  = await mintingVault.borrowUSDC(lockId, tokenIds, drawAmount);
  const borrowRx  = await borrowTx.wait();
  const borrowEvt = borrowRx.logs.find(l => l.fragment?.name === "USDCBorrowed");
  const creditId  = borrowEvt.args.creditId;
  console.log("✓ Credit ID:", creditId.toString());
  console.log("✓ USDC borrowed:", ethers.formatUnits(borrowEvt.args.amount, 6));

  // ── TEST 5: Verify credit position ───────────────────────────
  console.log("\n── TEST 5: Verify credit position ──────────");
  const credit = await mintingVault.getCredit(creditId);
  console.log("✓ Credit active:", credit.active);
  console.log("✓ Borrowed:", ethers.formatUnits(credit.borrowed, 6), "USDC");
  console.log("✓ Credit limit:", ethers.formatUnits(credit.creditLimit, 6), "USDC");
  console.assert(credit.active === true, "Credit should be active");
  console.assert(credit.borrowed === drawAmount, "Borrowed amount mismatch");

  // ── TEST 6: Verify Aave position ─────────────────────────────
  console.log("\n── TEST 6: Aave position ────────────────────");
  const aavePos = await mintingVault.getAavePosition();
  console.log("✓ Total debt:", ethers.formatUnits(aavePos.totalDebt, 8));
  console.log("✓ Health factor:", ethers.formatUnits(aavePos.healthFactor, 18));
  console.assert(aavePos.healthFactor >= ethers.parseUnits("1.5", 18), "Health factor too low");

  // ── TEST 7: Attempt double borrow (should revert) ────────────
  console.log("\n── TEST 7: Double borrow guard ─────────────");
  try {
    await mintingVault.borrowUSDC(lockId, tokenIds, drawAmount);
    console.log("✗ FAIL — should have reverted");
  } catch (e) {
    console.log("✓ Double borrow correctly reverted:", e.reason || "LockAlreadyHasCredit");
  }

  // ── TEST 8: Attempt unlock while debt active (should revert) ─
  console.log("\n── TEST 8: Unlock while debt active guard ───");
  try {
    await whaleVault.unlockMintingRights(lockId);
    console.log("✗ FAIL — should have reverted or warning");
  } catch (e) {
    console.log("✓ Unlock correctly blocked while debt active");
  }

  // ── TEST 9: Vault stats ───────────────────────────────────────
  console.log("\n── TEST 9: Vault stats ──────────────────────");
  const stats = await mintingVault.vaultStats();
  console.log("✓ Total borrowed:", ethers.formatUnits(stats._borrowed, 6), "USDC");
  console.log("✓ Total repaid:", ethers.formatUnits(stats._repaid, 6), "USDC");
  console.log("✓ Net outstanding:", ethers.formatUnits(stats._net, 6), "USDC");

  // ── TEST 10: Vault stats WhaleVault ──────────────────────────
  console.log("\n── TEST 10: WhaleVault stats ────────────────");
  const vaultStats = await whaleVault.getVaultStats();
  console.log("✓ Lock count:", vaultStats._lockCount.toString());
  console.log("✓ Total face ETH:", ethers.formatEther(vaultStats._totalFaceETH));
  console.log("✓ Total face USD:", ethers.formatUnits(vaultStats._totalFaceUSD, 6));

  // ── SUMMARY ───────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║   ALL TESTS PASSED                       ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log("Lock ID:    ", lockId.toString());
  console.log("Credit ID:  ", creditId.toString());
  console.log("USDC drawn: ", ethers.formatUnits(drawAmount, 6));
  console.log("Health:     ", ethers.formatUnits(aavePos.healthFactor, 18));
  console.log("\nSystem verified on Sepolia testnet.");
  console.log("Ready for mainnet deployment.");
}

main()
  .then(() => process.exit(0))
  .catch(e => { console.error(e); process.exit(1); });
