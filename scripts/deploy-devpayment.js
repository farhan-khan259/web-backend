const { ethers } = require("hardhat");

async function main() {
  const [owner]  = await ethers.getSigners();
  const network  = await ethers.provider.getNetwork();
  const isMainnet = network.chainId === 1n;

  const DEVELOPER_WALLET = process.env.DEVELOPER_WALLET || "PASTE_DEV_WALLET_HERE";
  const USDC = isMainnet
    ? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    : "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

  const Contract = await ethers.getContractFactory("EWBDevPayment");
  const escrow   = await Contract.deploy(DEVELOPER_WALLET, USDC);
  await escrow.waitForDeployment();
  const escrowAddr = await escrow.getAddress();
  console.log("DevPayment:", escrowAddr);
  console.log("VERIFY: npx hardhat verify --network", network.name,
    escrowAddr, '"' + DEVELOPER_WALLET + '"', '"' + USDC + '"');

  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync("./deployments/devpayment-" + network.name + "-" + Date.now() + ".json",
    JSON.stringify({ escrow: escrowAddr, developer: DEVELOPER_WALLET }, null, 2));
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
