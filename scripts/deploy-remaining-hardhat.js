const hre = require("hardhat");

async function deployContract(name, ...args) {
  console.log(`Deploying ${name}...`);
  const Factory = await hre.ethers.getContractFactory(name);
  const contract = await Factory.deploy(...args);
  await contract.waitForDeployment();
  console.log(`${name} deployed to:`, contract.target);
  return contract;
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "ETH");

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";
  const DEPLOYER = deployer.address;
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

  // Already deployed core addresses
  const ORACLE_ADDR = "0x5a82a37899219f58cBd21D7F1873554eb5A21bEe";
  const WHALE_ADDR = "0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529";

  // 1. EWBDevPayment
  const dev = await deployContract("EWBDevPayment", BALLET, DEPLOYER, USDC);

  // 2. EWBGasPaymaster (no args)
  const gas = await deployContract("EWBGasPaymaster");

  // 3. EWBLayer1Token (no args)
  const l1 = await deployContract("EWBLayer1Token");

  // 4. EWBLayer2Token (takes L1 address as distribution token)
  const l2 = await deployContract("EWBLayer2Token", l1.target);

  // 5. EWBLayer3Token (takes L1 address as distribution token)
  const l3 = await deployContract("EWBLayer3Token", l1.target);

  // 6. EWBMilestoneEscrow (developer, payment token)
  const escrow = await deployContract("EWBMilestoneEscrow", BALLET, USDC);

  // 7. EWBNFTHarvestVault (6 args)
  const nft = await deployContract("EWBNFTHarvestVault", BALLET, BALLET, WHALE_ADDR, ORACLE_ADDR, USDC, 200);

  // 8. EWBPrivateHarvest (3 args)
  const harvest = await deployContract("EWBPrivateHarvest", BALLET, BALLET, WHALE_ADDR);

  // 9. EWBPrivatePool (3 args)
  const pool = await deployContract("EWBPrivatePool", BALLET, BALLET, WHALE_ADDR);

  // 10. EWBRealWorldAsset (1 arg)
  const rwa = await deployContract("EWBRealWorldAsset", BALLET);

  // 11. EWBTWAPConnector (2 args)
  const twap = await deployContract("EWBTWAPConnector", ORACLE_ADDR, WHALE_ADDR);

  // 12. EWBTrademarkBridge (no args)
  const tm = await deployContract("EWBTrademarkBridge");

  console.log("\n✅ All 12 remaining contracts deployed!");
  console.log("EWBDevPayment:", dev.target);
  console.log("EWBGasPaymaster:", gas.target);
  console.log("EWBLayer1Token:", l1.target);
  console.log("EWBLayer2Token:", l2.target);
  console.log("EWBLayer3Token:", l3.target);
  console.log("EWBMilestoneEscrow:", escrow.target);
  console.log("EWBNFTHarvestVault:", nft.target);
  console.log("EWBPrivateHarvest:", harvest.target);
  console.log("EWBPrivatePool:", pool.target);
  console.log("EWBRealWorldAsset:", rwa.target);
  console.log("EWBTWAPConnector:", twap.target);
  console.log("EWBTrademarkBridge:", tm.target);
}

main().catch(console.error);
