const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();
  const isMainnet  = network.chainId === 1n;

  const USDC = isMainnet
    ? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    : "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";

  const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy("0x0000000000000000000000000000000000000000");
  await oracle.waitForDeployment();
  const oracleAddr = await oracle.getAddress();
  await (await oracle.setManualFloor(ethers.parseEther("4.29"))).wait();
  console.log("Oracle:", oracleAddr);

  const Vault = await ethers.getContractFactory("EWBWhaleVault");
  const vault = await Vault.deploy(USDC, oracleAddr);
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  const epicTokens = Array.from({ length: 16 }, (_, i) => i + 1);
  await (await vault.setTokenTiers(epicTokens, Array(16).fill(0))).wait();
  console.log("Vault:", vaultAddr);

  console.log("VERIFY ORACLE: npx hardhat verify --network", network.name,
    oracleAddr, '"0x0000000000000000000000000000000000000000"');
  console.log("VERIFY VAULT:  npx hardhat verify --network", network.name,
    vaultAddr, '"' + USDC + '"', '"' + oracleAddr + '"');

  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync("./deployments/" + network.name + "-" + Date.now() + ".json",
    JSON.stringify({ oracle: oracleAddr, vault: vaultAddr }, null, 2));
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
