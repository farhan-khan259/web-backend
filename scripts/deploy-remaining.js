const fs = require("fs");
const path = require("path");
const ethers = require("ethers");

async function deployContract(artifactName, factory, wallet, ...args) {
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
  const DEPLOYER = wallet.address;

  // Already deployed core addresses
  const ORACLE_ADDR = "0x5a82a37899219f58cBd21D7F1873554eb5A21bEe";
  const WHALE_ADDR = "0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529";
  const MINTING_ADDR = "0x2E4C26B33Ae96823e1C37cDbCB28dF0169A2738D";
  const ROUTER_ADDR = "0xC810418CFB38E4b6cfE7Cc0ACb1bb4d0CF318c80";
  const DELTA_ADDR = "0x173ee583c3263fBe41ac08B25484E9798102C12D";
  const BRIDGE_ADDR = "0xb4145e014A8338531f136FE73ECFed0dd452BA57";

  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

  const loadArtifact = (name) => {
    const p = path.join(__dirname, `../artifacts/contracts/${name}.sol/${name}.json`);
    return JSON.parse(fs.readFileSync(p, "utf8"));
  };

  // --- 1. EWBDevPayment ---
  const devArtifact = loadArtifact("EWBDevPayment");
  const devFactory = new ethers.ContractFactory(devArtifact.abi, devArtifact.bytecode, wallet);
  const dev = await deployContract("EWBDevPayment", devFactory, BALLET, DEPLOYER, USDC);

  // --- 2. EWBGasPaymaster ---
  const gasArtifact = loadArtifact("EWBGasPaymaster");
  const gasFactory = new ethers.ContractFactory(gasArtifact.abi, gasArtifact.bytecode, wallet);
  const gas = await deployContract("EWBGasPaymaster", gasFactory);

  // --- 3. EWBLayer1Token ---
  const l1Artifact = loadArtifact("EWBLayer1Token");
  const l1Factory = new ethers.ContractFactory(l1Artifact.abi, l1Artifact.bytecode, wallet);
  const l1 = await deployContract("EWBLayer1Token", l1Factory);

  // --- 4. EWBLayer2Token (depends on L1 as distribution token) ---
  const l2Artifact = loadArtifact("EWBLayer2Token");
  const l2Factory = new ethers.ContractFactory(l2Artifact.abi, l2Artifact.bytecode, wallet);
  const l2 = await deployContract("EWBLayer2Token", l2Factory, l1.target);

  // --- 5. EWBLayer3Token (depends on L1 as distribution token) ---
  const l3Artifact = loadArtifact("EWBLayer3Token");
  const l3Factory = new ethers.ContractFactory(l3Artifact.abi, l3Artifact.bytecode, wallet);
  const l3 = await deployContract("EWBLayer3Token", l3Factory, l1.target);

  // --- 6. EWBMilestoneEscrow ---
  const escrowArtifact = loadArtifact("EWBMilestoneEscrow");
  const escrowFactory = new ethers.ContractFactory(escrowArtifact.abi, escrowArtifact.bytecode, wallet);
  const escrow = await deployContract("EWBMilestoneEscrow", escrowFactory, BALLET, USDC);

  // --- 7. EWBNFTHarvestVault ---
  const nftArtifact = loadArtifact("EWBNFTHarvestVault");
  const nftFactory = new ethers.ContractFactory(nftArtifact.abi, nftArtifact.bytecode, wallet);
  const nft = await deployContract("EWBNFTHarvestVault", nftFactory, BALLET, BALLET, WHALE_ADDR, ORACLE_ADDR, USDC, 200);

  // --- 8. EWBPrivateHarvest ---
  const harvestArtifact = loadArtifact("EWBPrivateHarvest");
  const harvestFactory = new ethers.ContractFactory(harvestArtifact.abi, harvestArtifact.bytecode, wallet);
  const harvest = await deployContract("EWBPrivateHarvest", harvestFactory, BALLET, BALLET, WHALE_ADDR);

  // --- 9. EWBPrivatePool ---
  const poolArtifact = loadArtifact("EWBPrivatePool");
  const poolFactory = new ethers.ContractFactory(poolArtifact.abi, poolArtifact.bytecode, wallet);
  const pool = await deployContract("EWBPrivatePool", poolFactory, BALLET, BALLET, WHALE_ADDR);

  // --- 10. EWBRealWorldAsset ---
  const rwaArtifact = loadArtifact("EWBRealWorldAsset");
  const rwaFactory = new ethers.ContractFactory(rwaArtifact.abi, rwaArtifact.bytecode, wallet);
  const rwa = await deployContract("EWBRealWorldAsset", rwaFactory, BALLET);

  // --- 11. EWBTWAPConnector ---
  const twapArtifact = loadArtifact("EWBTWAPConnector");
  const twapFactory = new ethers.ContractFactory(twapArtifact.abi, twapArtifact.bytecode, wallet);
  const twap = await deployContract("EWBTWAPConnector", twapFactory, ORACLE_ADDR, WHALE_ADDR);

  // --- 12. EWBTrademarkBridge ---
  const tmArtifact = loadArtifact("EWBTrademarkBridge");
  const tmFactory = new ethers.ContractFactory(tmArtifact.abi, tmArtifact.bytecode, wallet);
  const tm = await deployContract("EWBTrademarkBridge", tmFactory);

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