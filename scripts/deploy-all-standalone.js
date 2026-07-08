const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

async function deployContract(artifactName, factory, ...args) {
  console.log(`Deploying ${artifactName}...`);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  console.log(`${artifactName} deployed to:`, contract.target);
  return contract;
}

async function main() {
  const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth-mainnet.g.alchemy.com/v2/DaXupNusiArJ84o7YqJUk";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("Deployer:", wallet.address);
  console.log("Balance:", ethers.formatEther(await provider.getBalance(wallet.address)), "ETH");

  const BALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

  const loadArtifact = (name) => {
    const p = path.join(__dirname, `../artifacts/contracts/${name}.sol/${name}.json`);
    return JSON.parse(fs.readFileSync(p, "utf8"));
  };

  const oracleArtifact = loadArtifact("EWBGorillaOracle");
  const whaleArtifact = loadArtifact("EWBWhaleVault");
  const mintingArtifact = loadArtifact("EWBMintingRightsVault");
  const routerArtifact = loadArtifact("EWBRevenueRouter");
  const deltaArtifact = loadArtifact("EWBDeltaNeutralVault");
  const bridgeArtifact = loadArtifact("EWBCreditBridge");

  const oracleFactory = new ethers.ContractFactory(oracleArtifact.abi, oracleArtifact.bytecode, wallet);
  const oracle = await deployContract("EWBGorillaOracle", oracleFactory, "0x0000000000000000000000000000000000000000", BALLET);

  const whaleFactory = new ethers.ContractFactory(whaleArtifact.abi, whaleArtifact.bytecode, wallet);
  const whale = await deployContract("EWBWhaleVault", whaleFactory, oracle.target);

  const mintingFactory = new ethers.ContractFactory(mintingArtifact.abi, mintingArtifact.bytecode, wallet);
  const minting = await deployContract("EWBMintingRightsVault", mintingFactory, whale.target);

  const routerFactory = new ethers.ContractFactory(routerArtifact.abi, routerArtifact.bytecode, wallet);
  const router = await deployContract("EWBRevenueRouter", routerFactory, wallet.address, minting.target);

  const deltaFactory = new ethers.ContractFactory(deltaArtifact.abi, deltaArtifact.bytecode, wallet);
  const delta = await deployContract("EWBDeltaNeutralVault", deltaFactory, BALLET, BALLET, router.target);

  const bridgeFactory = new ethers.ContractFactory(bridgeArtifact.abi, bridgeArtifact.bytecode, wallet);
  const bridge = await deployContract("EWBCreditBridge", bridgeFactory, minting.target, delta.target);

  console.log("\n✅ All contracts deployed on mainnet!");
  console.log("Oracle:", oracle.target);
  console.log("WhaleVault:", whale.target);
  console.log("MintingRightsVault:", minting.target);
  console.log("RevenueRouter:", router.target);
  console.log("DeltaNeutralVault:", delta.target);
  console.log("CreditBridge:", bridge.target);

  const data = {
    network: "mainnet",
    oracle: oracle.target,
    whaleVault: whale.target,
    mintingVault: minting.target,
    revenueRouter: router.target,
    deltaNeutralVault: delta.target,
    creditBridge: bridge.target,
  };
  fs.writeFileSync("./deployments/mainnet-all.json", JSON.stringify(data, null, 2));
  console.log("\n✅ Addresses saved to ./deployments/mainnet-all.json");
}

main().catch(console.error);
