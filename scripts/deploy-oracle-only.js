const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

  const Oracle = await hre.ethers.getContractFactory("EWBGorillaOracle");
  const oracle = await Oracle.deploy("0x0000000000000000000000000000000000000000", BALLET);
  await oracle.waitForDeployment();
  console.log("Oracle deployed to:", oracle.target);
}

main().catch(console.error);
