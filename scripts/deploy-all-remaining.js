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
  const DEPLOYER = wallet.address;
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const ORACLE_ADDR = "0x5a82a37899219f58cBd21D7F1873554eb5A21bEe";
  const WHALE_ADDR = "0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529";

  const loadArtifact = (name) => {
    const p = path.join(__dirname, `../artifacts/contracts/${name}.sol/${name}.json`);
    return JSON.parse(fs.readFileSync(p, "utf8"));
  };

  const oracleArtifact = loadArtifact("EWBGorillaOracle");
  const oracleContract = new ethers.Contract(ORACLE_ADDR, oracleArtifact.abi, wallet);

  async function ensureOracleReady() {
    try {
      await oracleContract.getFloorPriceETH();
      return;
    } catch (err) {
      const message = err?.reason || err?.error?.message || err?.message || "";
      if (!message.includes("Pool not set") && !message.includes("Manual floor price is stale")) {
        throw err;
      }
      const oracleOwner = await oracleContract.owner();
      if (oracleOwner.toLowerCase() !== wallet.address.toLowerCase()) {
        throw new Error(
          `Oracle at ${ORACLE_ADDR} is not initialized and deployer is not oracle owner (${oracleOwner}). ` +
          `Set the TWAP pool or manual floor on that oracle before deploying EWBTWAPConnector.`
        );
      }
      console.log("Oracle not ready. Deployer owns oracle, initializing manual floor to 4.29 ETH...");
      await (await oracleContract.setManualFloor(ethers.parseEther("4.29"))).wait();
      await (await oracleContract.setManualFloorMaxAge(1800)).wait();
      console.log("Oracle manual floor initialized.");
    }
  }

  await ensureOracleReady();

  // 1. EWBGasPaymaster
  const gasArtifact = loadArtifact("EWBGasPaymaster");
  const gasFactory = new ethers.ContractFactory(gasArtifact.abi, gasArtifact.bytecode, wallet);
  const gas = await deployContract("EWBGasPaymaster", gasFactory);

  // 2. EWBLayer1Token
  const l1Artifact = loadArtifact("EWBLayer1Token");
  const l1Factory = new ethers.ContractFactory(l1Artifact.abi, l1Artifact.bytecode, wallet);
  const l1 = await deployContract("EWBLayer1Token", l1Factory);

  // 3. EWBLayer2Token (depends on L1)
  const l2Artifact = loadArtifact("EWBLayer2Token");
  const l2Factory = new ethers.ContractFactory(l2Artifact.abi, l2Artifact.bytecode, wallet);
  const l2 = await deployContract("EWBLayer2Token", l2Factory, l1.target);

  // 4. EWBLayer3Token (depends on L1)
  const l3Artifact = loadArtifact("EWBLayer3Token");
  const l3Factory = new ethers.ContractFactory(l3Artifact.abi, l3Artifact.bytecode, wallet);
  const l3 = await deployContract("EWBLayer3Token", l3Factory, l1.target);

  // 5. EWBMilestoneEscrow
  const escrowArtifact = loadArtifact("EWBMilestoneEscrow");
  const escrowFactory = new ethers.ContractFactory(escrowArtifact.abi, escrowArtifact.bytecode, wallet);
  const escrow = await deployContract("EWBMilestoneEscrow", escrowFactory, BALLET, USDC);

  // 6. EWBNFTHarvestVault
  const nftArtifact = loadArtifact("EWBNFTHarvestVault");
  const nftFactory = new ethers.ContractFactory(nftArtifact.abi, nftArtifact.bytecode, wallet);
  const nft = await deployContract("EWBNFTHarvestVault", nftFactory, BALLET, BALLET, WHALE_ADDR, ORACLE_ADDR, USDC, 200);

  // 7. EWBPrivateHarvest
  const harvestArtifact = loadArtifact("EWBPrivateHarvest");
  const harvestFactory = new ethers.ContractFactory(harvestArtifact.abi, harvestArtifact.bytecode, wallet);
  const harvest = await deployContract("EWBPrivateHarvest", harvestFactory, BALLET, BALLET, WHALE_ADDR);

  // 8. EWBPrivatePool
  const poolArtifact = loadArtifact("EWBPrivatePool");
  const poolFactory = new ethers.ContractFactory(poolArtifact.abi, poolArtifact.bytecode, wallet);
  const pool = await deployContract("EWBPrivatePool", poolFactory, BALLET, BALLET, WHALE_ADDR);

  // 9. EWBRealWorldAsset
  const rwaArtifact = loadArtifact("EWBRealWorldAsset");
  const rwaFactory = new ethers.ContractFactory(rwaArtifact.abi, rwaArtifact.bytecode, wallet);
  const rwa = await deployContract("EWBRealWorldAsset", rwaFactory, BALLET);

  // 10. EWBTWAPConnector
  const twapArtifact = loadArtifact("EWBTWAPConnector");
  const twapFactory = new ethers.ContractFactory(twapArtifact.abi, twapArtifact.bytecode, wallet);
  const twap = await deployContract("EWBTWAPConnector", twapFactory, ORACLE_ADDR, WHALE_ADDR);

  // 11. EWBTrademarkBridge
  const tmArtifact = loadArtifact("EWBTrademarkBridge");
  const tmFactory = new ethers.ContractFactory(tmArtifact.abi, tmArtifact.bytecode, wallet);
  const tm = await deployContract("EWBTrademarkBridge", tmFactory);

  console.log("\n✅ All remaining contracts deployed!");
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
