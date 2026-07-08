/**
 * EWBDeltaNeutralVault Deploy Script
 *
 * MULTISIG SETUP REQUIRED BEFORE DEPLOYING:
 * 1. Create a Gnosis Safe at https://app.safe.global
 * 2. Set threshold: 2-of-3
 * 3. Add signers:
 *    - Hardware wallet A (Ledger)
 *    - Hardware wallet B (Trezor)
 *    - Emergency backup key (cold storage)
 * 4. Copy the Safe address into SAFE_MULTISIG_ADDRESS in .env
 * 5. The Safe address becomes the deed wallet — all admin calls need 2 signers
 *
 * SINGLE OPERATOR ALTERNATIVE:
 * If no multisig, use your hardware wallet address directly.
 * Accepted risk: single point of failure.
 */
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();

  const Vault = await ethers.getContractFactory("EWBDeltaNeutralVault");
  const vault = await Vault.deploy();
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log("Delta-Neutral Vault:", vaultAddr);
  console.log("VERIFY: npx hardhat verify --network", network.name, vaultAddr);

  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync("./deployments/dn-" + network.name + "-" + Date.now() + ".json",
    JSON.stringify({ vault: vaultAddr, owner: deployer.address }, null, 2));
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
