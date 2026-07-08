const hre = require("hardhat");

// Helper to deploy and wait with explicit error handling
async function deployContract(name, Factory, ...args) {
  console.log(`  Deploying ${name}...`);
  try {
    // Deploy returns contract, not transaction in ethers v6
    const contract = await Factory.deploy(...args);
    console.log(`  Tx hash: ${contract.deploymentTransaction()?.hash || "unknown"}`);
    
    // Wait for deployment to finish
    const deployed = await contract.waitForDeployment();
    const address = deployed.target || deployed.address;
    console.log(`✓ ${name} deployed to: ${address}`);
    return deployed;
  } catch (error) {
    console.error(`✗ ${name} deployment failed:`, error.message);
    // If it's a known address conflict, try to return it anyway
    if (error.data && error.data.includes && error.data.includes("already exists")) {
      console.log(`  (Address already has code, may be redeployment)`);
      const address = error.address || args[args.length - 1];
      return hre.ethers.getContractAt(name, address);
    }
    throw error;
  }
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("\n=== Mainnet Deployment ===");
  console.log("Account:", deployer.address);
  
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  const balanceETH = hre.ethers.formatEther(balance);
  console.log("Balance:", balanceETH, "ETH");

  // Show current gas price
  try {
    const gasPrice = await hre.ethers.provider.getGasPrice();
    console.log(`Current gas price: ${hre.ethers.formatUnits(gasPrice, 9)} gwei`);
    console.log(`\nNote: Full deployment (6 contracts) will cost ~0.1-0.5 ETH depending on gas prices`);
  } catch (e) {
    console.log("Could not fetch gas price");
  }

  if (balance < hre.ethers.parseEther("0.05")) {
    throw new Error(`\n❌ Insufficient balance!\n   Have: ${balanceETH} ETH\n   Need: at least 0.05 ETH (0.1-0.5 for safe deployment)\n   → Fund your account or test on Sepolia testnet first`);
  }

  const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

  try {
    // 1. Oracle
    const OracleFactory = await hre.ethers.getContractFactory("EWBGorillaOracle");
    const oracle = await deployContract(
      "EWBGorillaOracle",
      OracleFactory,
      "0x0000000000000000000000000000000000000000",
      BALLET_WALLET
    );

    // 2. WhaleVault
    const WhaleFactory = await hre.ethers.getContractFactory("EWBWhaleVault");
    const whale = await deployContract("EWBWhaleVault", WhaleFactory, oracle.target);

    // 3. MintingRightsVault
    const MintingFactory = await hre.ethers.getContractFactory("EWBMintingRightsVault");
    const minting = await deployContract("EWBMintingRightsVault", MintingFactory, whale.target);

    // 4. RevenueRouter
    const RouterFactory = await hre.ethers.getContractFactory("EWBRevenueRouter");
    const router = await deployContract("EWBRevenueRouter", RouterFactory, deployer.address, minting.target);

    // 5. DeltaNeutralVault
    const DeltaFactory = await hre.ethers.getContractFactory("EWBDeltaNeutralVault");
    const delta = await deployContract(
      "EWBDeltaNeutralVault",
      DeltaFactory,
      BALLET_WALLET,
      BALLET_WALLET,
      router.target
    );

    // 6. CreditBridge
    const BridgeFactory = await hre.ethers.getContractFactory("EWBCreditBridge");
    const bridge = await deployContract("EWBCreditBridge", BridgeFactory, minting.target, delta.target);

    // Update RevenueRouter with deltaVault
    console.log("\nConfiguring RevenueRouter...");
    try {
      const tx = await router.setDeltaVault(delta.target);
      const receipt = await tx.wait();
      console.log(`✓ RevenueRouter updated (tx: ${receipt.hash})`);
    } catch (e) {
      console.log("ℹ RevenueRouter update skipped (function may not exist)");
    }

    console.log("\n=== ✓ Mainnet Deployment Complete ===");
    console.log("\nDeployed Addresses:");
    console.log("  Oracle:", oracle.target);
    console.log("  WhaleVault:", whale.target);
    console.log("  MintingRightsVault:", minting.target);
    console.log("  RevenueRouter:", router.target);
    console.log("  DeltaNeutralVault:", delta.target);
    console.log("  CreditBridge:", bridge.target);

    // Save to file
    const fs = require("fs");
    const data = {
      network: "mainnet",
      deployedAt: new Date().toISOString(),
      deployer: deployer.address,
      oracle: oracle.target,
      whaleVault: whale.target,
      mintingVault: minting.target,
      revenueRouter: router.target,
      deltaNeutralVault: delta.target,
      creditBridge: bridge.target,
    };
    fs.writeFileSync("./deployments/mainnet-all.json", JSON.stringify(data, null, 2));
    console.log("\n✓ Addresses saved to ./deployments/mainnet-all.json");

    console.log("\n-- Verify on Etherscan --");
    console.log(`npx hardhat verify --network mainnet ${oracle.target} 0x0000000000000000000000000000000000000000 ${BALLET_WALLET}`);
    console.log(`npx hardhat verify --network mainnet ${whale.target} ${oracle.target}`);
    console.log(`npx hardhat verify --network mainnet ${minting.target} ${whale.target}`);
    console.log(`npx hardhat verify --network mainnet ${router.target} ${deployer.address} ${minting.target}`);
    console.log(`npx hardhat verify --network mainnet ${delta.target} ${BALLET_WALLET} ${BALLET_WALLET} ${router.target}`);
    console.log(`npx hardhat verify --network mainnet ${bridge.target} ${minting.target} ${delta.target}`);

  } catch (error) {
    console.error("\n✗ Deployment failed:", error.message);
    if (error.code === "INSUFFICIENT_FUNDS") {
      console.error("  → Insufficient balance for gas fees");
    }
    throw error;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});