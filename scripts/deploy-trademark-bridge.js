/**
 * EWB Trademark Bridge — Deploy Script
 *
 * Deploys EWBTrademarkBridge and optionally anchors
 * IPFS document hashes if provided in environment.
 *
 * USAGE:
 *   npx hardhat run scripts/deploy-trademark-bridge.js --network sepolia
 *   npx hardhat run scripts/deploy-trademark-bridge.js --network mainnet
 *
 * OPTIONAL ENV VARS FOR IPFS ANCHORING:
 *   IPFS_CERTIFICATE=QmXxx...      (trademark certificate PDF)
 *   IPFS_LICENCE=QmXxx...          (licence agreement PDF)
 *   IPFS_LEGAL_OPINION=QmXxx...    (solicitor legal opinion)
 *   IPFS_SPV_AGREEMENT=QmXxx...    (SPV beneficial ownership doc)
 *   LEGAL_DECLARATION=text...      (owner declaration statement)
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();

  // ── IPFS HASHES (optional — can be set after deployment) ───
  const IPFS_CERT        = process.env.IPFS_CERTIFICATE    || "";
  const IPFS_LICENCE     = process.env.IPFS_LICENCE        || "";
  const IPFS_OPINION     = process.env.IPFS_LEGAL_OPINION  || "";
  const IPFS_SPV         = process.env.IPFS_SPV_AGREEMENT  || "";
  const DECLARATION      = process.env.LEGAL_DECLARATION   ||
    "UK trademark UK00003897277 is hereby designated with the SPV Treasury " +
    "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf as the sole beneficiary of " +
    "all trademark proceeds and licensing revenue. This declaration is " +
    "irrevocable and forms part of the EWB Whale Vault ecosystem.";

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║    EWB TRADEMARK BRIDGE — DEPLOY        ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log("Network:     ", network.name);
  console.log("Deployer:    ", deployer.address);
  console.log("Trademark:    UK00003897277");
  console.log("Owner:        Wayne Fyffe");
  console.log("SPV Treasury: 0xc82A59594560A3010F336ebe2e9CC4794DCD46cf");
  console.log();

  // ── DEPLOY ─────────────────────────────────────────────────
  console.log(">> Deploying EWBTrademarkBridge...");
  const Bridge = await ethers.getContractFactory("EWBTrademarkBridge");
  const bridge = await Bridge.deploy();
  await bridge.waitForDeployment();
  const bridgeAddress = await bridge.getAddress();
  console.log("   Bridge deployed:", bridgeAddress);

  // ── BRIDGE 1: ANCHOR IPFS DOCUMENTS ────────────────────────
  console.log("\n>> Anchoring documents...");

  if (IPFS_CERT) {
    await (await bridge.anchorCertificate(IPFS_CERT)).wait();
    console.log("   Certificate anchored:", IPFS_CERT);
  } else {
    console.log("   ⚠  Certificate: set IPFS_CERTIFICATE in .env then call:");
    console.log("      await bridge.anchorCertificate('<IPFS_HASH>')");
  }

  if (IPFS_LICENCE) {
    await (await bridge.anchorLicenceAgreement(IPFS_LICENCE)).wait();
    console.log("   Licence agreement anchored:", IPFS_LICENCE);
  } else {
    console.log("   ⚠  Licence: set IPFS_LICENCE in .env then call:");
    console.log("      await bridge.anchorLicenceAgreement('<IPFS_HASH>')");
  }

  if (IPFS_OPINION) {
    await (await bridge.anchorLegalOpinion(IPFS_OPINION)).wait();
    console.log("   Legal opinion anchored:", IPFS_OPINION);
  } else {
    console.log("   ⚠  Legal opinion: set IPFS_LEGAL_OPINION in .env then call:");
    console.log("      await bridge.anchorLegalOpinion('<IPFS_HASH>')");
  }

  if (IPFS_SPV) {
    await (await bridge.anchorSPVAgreement(IPFS_SPV)).wait();
    console.log("   SPV agreement anchored:", IPFS_SPV);
  } else {
    console.log("   ⚠  SPV agreement: set IPFS_SPV_AGREEMENT in .env then call:");
    console.log("      await bridge.anchorSPVAgreement('<IPFS_HASH>')");
  }

  // ── BRIDGE 3: LEGAL DECLARATION ────────────────────────────
  console.log("\n>> Making legal declaration...");
  await (await bridge.makeDeclaration(DECLARATION)).wait();
  console.log("   Declaration recorded on-chain ✓");
  console.log("   Declaration:", DECLARATION.substring(0, 80) + "...");

  // ── ACTIVATE BRIDGE (if all docs anchored) ──────────────────
  if (IPFS_CERT && IPFS_LICENCE) {
    console.log("\n>> Activating bridge (cert + licence + declaration present)...");
    await (await bridge.activateBridge()).wait();
    console.log("   Bridge ACTIVE ✓");
  } else {
    console.log("\n⚠  Bridge not yet activated — requires certificate + licence.");
    console.log("   After anchoring both documents call:");
    console.log("   await bridge.activateBridge()");
  }

  // ── VERIFY STATUS ───────────────────────────────────────────
  const [cert, lic, opinion, spv, decl, active, royalties, days] =
    await bridge.getBridgeStatus();
  console.log("\n>> Bridge status:");
  console.log("   Certificate:   ", cert    ? "✓" : "✗ pending");
  console.log("   Licence:       ", lic     ? "✓" : "✗ pending");
  console.log("   Legal opinion: ", opinion ? "✓" : "✗ pending");
  console.log("   SPV agreement: ", spv     ? "✓" : "✗ pending");
  console.log("   Declaration:   ", decl    ? "✓" : "✗ pending");
  console.log("   Active:        ", active  ? "✓ ACTIVE" : "✗ not yet");
  console.log("   Days to renewal:", days.toString());

  // ── VERIFICATION ────────────────────────────────────────────
  console.log("\nVERIFY:");
  console.log(`npx hardhat verify --network ${network.name} ${bridgeAddress}`);

  // ── CONSOLE COMMANDS ────────────────────────────────────────
  console.log("\nCONSOLE COMMANDS:");
  console.log(`const bridge = await ethers.getContractAt("EWBTrademarkBridge", "${bridgeAddress}")`);
  console.log("await bridge.TRADEMARK_NUMBER()");
  console.log("await bridge.daysUntilRenewal()");
  console.log("await bridge.getBridgeStatus()");
  console.log("await bridge.anchorCertificate('<IPFS_HASH>')");
  console.log("await bridge.anchorLicenceAgreement('<IPFS_HASH>')");
  console.log("await bridge.anchorLegalOpinion('<IPFS_HASH>')");
  console.log("await bridge.anchorSPVAgreement('<IPFS_HASH>')");
  console.log("await bridge.activateBridge()");
  console.log("await bridge.getRoyaltyCount()");

  // ── SAVE RECORD ─────────────────────────────────────────────
  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(
    `./deployments/trademark-bridge-${network.name}-${Date.now()}.json`,
    JSON.stringify({
      network:       network.name,
      bridge:        bridgeAddress,
      owner:         deployer.address,
      trademark:     "UK00003897277",
      spvTreasury:   "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf",
      certificateAnchored: !!IPFS_CERT,
      licenceAnchored:     !!IPFS_LICENCE,
      declarationMade:     true,
      bridgeActive:        !!(IPFS_CERT && IPFS_LICENCE),
      deployedAt:    new Date().toISOString(),
    }, null, 2)
  );
  console.log("\nDeployment record saved.");
}

main().then(() => process.exit(0)).catch(e => {
  console.error(e); process.exit(1);
});
