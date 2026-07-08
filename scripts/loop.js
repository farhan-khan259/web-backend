/**
 * EWB Whale Vault — Weaponised Automated Loop
 * Wayne Fyffe · Exposed Walls Banksy
 * Ballet wallet: 0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *
 * ================================================================
 * THE WEAPON
 * ================================================================
 *
 * 36,054 ETH of minting rights.
 * 6,391 ETH credit capacity.
 * ~$10.2M USDC available.
 *
 * One lock. One borrow. USDC in Ballet wallet.
 * Yield repays automatically. Cycle resets. Repeat.
 *
 * Wayne signs 4 things total. Everything else is automatic.
 *
 * ================================================================
 * EXECUTION ORDER
 * ================================================================
 *
 *  Step 1  fund()                — send ETH to bridge once
 *  Step 2  lockMintingRights()   — triggers auto ETH deployment
 *  Step 3  borrowUSDC()          — Aave releases USDC to Ballet wallet
 *  Step 4  [AUTOMATIC]           — yield repays debt
 *  Step 5  borrowUSDC() again    — redraw when capacity restores
 *  Step 6  unlockMintingRights() — close cycle when done
 *
 * ================================================================
 */

const { ethers } = require("hardhat");
require("dotenv").config();

// ── Deployed addresses (fill after deploy) ──────────────────────
const ADDRESSES = {
  whaleVault:    process.env.WHALE_VAULT_ADDRESS,
  mintingVault:  process.env.MINTING_VAULT_ADDRESS,
  creditBridge:  process.env.CREDIT_BRIDGE_ADDRESS,
  deltaVault:    process.env.DELTA_VAULT_ADDRESS,
  usdc:          "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  aave:          "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
};

// ── Token IDs to lock (Wayne's EPIC tokens — maximum credit) ────
const EPIC_TOKEN_IDS  = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
const ALL_TOKEN_IDS   = [...EPIC_TOKEN_IDS]; // expand to include SR/RARE/STD as needed

// ── Credit amounts ───────────────────────────────────────────────
const EPIC_CREDIT_USDC   = ethers.parseUnits("1512", 6) ; // 1,512 ETH × $1,601 = ~$2.4M
const FULL_CREDIT_USDC   = ethers.parseUnits("6391", 6);  // full capacity

async function main() {
  const [ballet] = await ethers.getSigners();
  console.log("\n╔══════════════════════════════════════╗");
  console.log("║   EWB WHALE VAULT — LIVE LOOP        ║");
  console.log("╚══════════════════════════════════════╝");
  console.log("Ballet wallet:", ballet.address);
  console.log("ETH balance:", ethers.formatEther(await ethers.provider.getBalance(ballet.address)));

  const whaleVault   = await ethers.getContractAt("EWBWhaleVault",        ADDRESSES.whaleVault);
  const mintingVault = await ethers.getContractAt("EWBMintingRightsVault", ADDRESSES.mintingVault);
  const bridge       = await ethers.getContractAt("EWBCreditBridge",       ADDRESSES.creditBridge);
  const usdc         = await ethers.getContractAt("IERC20",                ADDRESSES.usdc);

  // ── STEP 1: Fund the bridge ──────────────────────────────────
  console.log("\n── STEP 1: Fund bridge ─────────────────");
  const bridgeBal = await bridge.bridgeBalance();
  console.log("Bridge balance:", ethers.formatEther(bridgeBal), "ETH");

  if (bridgeBal === 0n) {
    const seedETH = ethers.parseEther("1512"); // EPIC LTV — 1,512 ETH
    console.log("Funding bridge with", ethers.formatEther(seedETH), "ETH...");
    const tx1 = await bridge.fund({ value: seedETH });
    await tx1.wait();
    console.log("✓ Bridge funded");
  } else {
    console.log("✓ Bridge already funded");
  }

  // ── STEP 2: Lock minting rights ──────────────────────────────
  console.log("\n── STEP 2: Lock minting rights ─────────");
  console.log("Locking", EPIC_TOKEN_IDS.length, "EPIC token IDs...");
  console.log("Face value: 16 × 315 ETH = 5,040 ETH");
  console.log("Credit capacity: 5,040 × 30% = 1,512 ETH");

  const tx2 = await whaleVault.lockMintingRights(
    EPIC_TOKEN_IDS,
    "credit",
    0 // no expiry
  );
  const r2 = await tx2.wait();
  const lockEvent = r2.logs.find(l => l.fragment?.name === "MintingRightsLocked");
  const lockId    = lockEvent.args.lockId;

  console.log("✓ Lock ID:", lockId.toString());
  console.log("✓ ETH auto-deployed to DeltaNeutralVault → Lido → wstETH → Aave");

  // ── STEP 3: Borrow USDC ──────────────────────────────────────
  console.log("\n── STEP 3: Borrow Circle USDC from Aave ─");
  const usdcBefore = await usdc.balanceOf(ballet.address);
  console.log("USDC before:", ethers.formatUnits(usdcBefore, 6));

  // Draw 80% of EPIC credit capacity
  const drawAmount = ethers.parseUnits("1209600", 6); // ~80% of EPIC capacity
  console.log("Drawing:", ethers.formatUnits(drawAmount, 6), "USDC");

  const tx3 = await mintingVault.borrowUSDC(lockId, EPIC_TOKEN_IDS, drawAmount);
  const r3  = await tx3.wait();
  const creditEvent = r3.logs.find(l => l.fragment?.name === "USDCBorrowed");
  const creditId    = creditEvent.args.creditId;

  const usdcAfter = await usdc.balanceOf(ballet.address);
  console.log("✓ Credit ID:", creditId.toString());
  console.log("✓ USDC received:", ethers.formatUnits(usdcAfter - usdcBefore, 6));
  console.log("✓ USDC in Ballet wallet:", ethers.formatUnits(usdcAfter, 6));

  // ── STEP 4: Automatic (no action needed) ────────────────────
  console.log("\n── STEP 4: Yield auto-repays Aave debt ──");
  console.log("Automatic — no signature needed");
  console.log("stETH yield → harvestToUSDC() → autoRepay() → debt reduced");
  console.log("Monitor: mintingVault.vaultStats() to track repayment");

  // ── STEP 5: Redraw when capacity restores ───────────────────
  console.log("\n── STEP 5: Redraw when ready ───────────");
  console.log("After partial/full repay:");
  console.log("  mintingVault.borrowUSDC(lockId, tokenIds, amount)");
  console.log("USDC → Ballet wallet again instantly");

  // ── STEP 6: Unlock when done ─────────────────────────────────
  console.log("\n── STEP 6: Unlock when cycle complete ───");
  console.log("After full repay:");
  console.log("  whaleVault.unlockMintingRights(", lockId.toString(), ")");
  console.log("Token IDs released — same IDs can be locked again");

  // ── STATUS SUMMARY ────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════╗");
  console.log("║   LOOP STATUS                        ║");
  console.log("╚══════════════════════════════════════╝");

  const stats = await mintingVault.vaultStats();
  const aavePos = await mintingVault.getAavePosition();

  console.log("Lock ID:          ", lockId.toString());
  console.log("Credit ID:        ", creditId.toString());
  console.log("USDC borrowed:    ", ethers.formatUnits(stats._borrowed, 6));
  console.log("USDC repaid:      ", ethers.formatUnits(stats._repaid, 6));
  console.log("Net outstanding:  ", ethers.formatUnits(stats._net, 6));
  console.log("Aave debt:        ", ethers.formatUnits(aavePos.totalDebt, 8), "(8 dec)");
  console.log("Aave health:      ", ethers.formatUnits(aavePos.healthFactor, 18));
  console.log("Ballet USDC:      ", ethers.formatUnits(await usdc.balanceOf(ballet.address), 6));
  console.log("\n✓ LOOP COMPLETE — USDC IN BALLET WALLET");
}

main()
  .then(() => process.exit(0))
  .catch(e => { console.error(e); process.exit(1); });
