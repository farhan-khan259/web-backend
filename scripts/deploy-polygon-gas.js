/**
 * Deploy EWBGasPaymaster on Polygon
 * Cost: ~$0.01 in MATIC
 * Purpose: Fund Ethereum mainnet gas fees cheaply
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying from:", deployer.address);
  console.log("Network: Polygon");

  const GasPaymaster = await ethers.getContractFactory("EWBGasPaymaster");
  const paymaster    = await GasPaymaster.deploy();
  await paymaster.waitForDeployment();

  const addr = await paymaster.getAddress();
  console.log("\n✓ EWBGasPaymaster deployed on Polygon:", addr);
  console.log("\nNext steps:");
  console.log("1. Send $2 of MATIC to:", addr);
  console.log("2. Call fundMainnetGas() with that MATIC");
  console.log("3. Wait 30 min for bridge");
  console.log("4. ETH arrives at Ballet wallet on Ethereum mainnet");
  console.log("5. Deploy EWB contracts on mainnet");
}

main()
  .then(() => process.exit(0))
  .catch(e => { console.error(e); process.exit(1); });
