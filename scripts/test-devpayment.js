const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

  const DevPayment = await hre.ethers.getContractFactory("EWBDevPayment");
  const contract = await DevPayment.deploy(BALLET, deployer.address, USDC);
  await contract.waitForDeployment();
  console.log("EWBDevPayment deployed to:", contract.target);
}

main().catch(console.error);
