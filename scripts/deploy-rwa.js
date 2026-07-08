/**
 * EWBRealWorldAsset Deploy Script
 *
 * DEPLOY ORDER:
 * 1. Deploy contract (pass Safe multisig address)
 * 2. anchorDocument("appraisal", "<IPFS_CID>", "Dr. Lori Verderame appraisal Feb 2026")
 * 3. anchorDocument("provenance", "<IPFS_CID>", "Ownership and acquisition history")
 * 4. anchorDocument("insurance", "<IPFS_CID>", "Insurance certificate")
 * 5. anchorDocument("trademark", "<IPFS_CID>", "UK00003897277 registration certificate")
 * 6. anchorDocument("payment", "<IPFS_CID>", "Lloyds Bank payment confirmation")
 * 7. anchorDocument("declaration", "<IPFS_CID>", "Irrevocable ownership declaration")
 * 8. finalise() — makes record permanently immutable
 *
 * After finalise(): core data is immutable. New docs can be added.
 */
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const safeMultisig = process.env.SAFE_MULTISIG_ADDRESS;

  if (!safeMultisig) throw new Error("SAFE_MULTISIG_ADDRESS not set in .env");

  console.log("Deploying EWBRealWorldAsset...");
  console.log("  Deployer:  ", deployer.address);
  console.log("  Safe:      ", safeMultisig);

  const RWA = await ethers.getContractFactory("EWBRealWorldAsset");
  const rwa = await RWA.deploy(safeMultisig);
  await rwa.waitForDeployment();

  const addr = await rwa.getAddress();
  console.log("  Deployed:  ", addr);

  // Verify initial state
  const summary = await rwa.getSummary();
  console.log("\nAsset:", summary.name);
  console.log("FMV Low:  $" + (Number(summary.fmvLow) / 1e6).toLocaleString());
  console.log("FMV High: $" + (Number(summary.fmvHigh) / 1e6).toLocaleString());
  console.log("Finalised:", summary.finalised);
  console.log("Trademark:", summary.trademark);

  console.log("\nNext steps:");
  console.log("  1. anchorDocument('appraisal', <IPFS_CID>, 'description')");
  console.log("  2. anchorDocument('provenance', <IPFS_CID>, 'description')");
  console.log("  3. anchorDocument('declaration', <IPFS_CID>, 'description')");
  console.log("  4. finalise() — immutable after this");
}

main().catch(err => { console.error(err); process.exit(1); });
