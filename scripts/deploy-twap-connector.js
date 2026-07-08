/**
 * EWB TWAP Connector — Deploy and Connect
 *
 * Deploys EWBTWAPConnector and connects it to:
 *   - EWBGorillaOracle (price source)
 *   - EWBLayer1Token
 *   - EWBLayer2Token
 *   - EWBLayer3Token
 *   - EWBWhaleVault
 *
 * USAGE:
 *   npx hardhat run scripts/deploy-twap-connector.js --network sepolia
 *   npx hardhat run scripts/deploy-twap-connector.js --network mainnet
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();

  // !! FILL THESE IN AFTER OTHER CONTRACTS ARE DEPLOYED !!
  const ORACLE_ADDRESS = process.env.ORACLE_ADDRESS  || "PASTE_ORACLE_ADDRESS";
  const L1T_ADDRESS    = process.env.L1T_ADDRESS     || "PASTE_L1T_ADDRESS";
  const L2T_ADDRESS    = process.env.L2T_ADDRESS     || "PASTE_L2T_ADDRESS";
  const L3T_ADDRESS    = process.env.L3T_ADDRESS     || "PASTE_L3T_ADDRESS";
  const VAULT_ADDRESS  = process.env.VAULT_ADDRESS   || "PASTE_VAULT_ADDRESS";

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║      EWB TWAP CONNECTOR — DEPLOY        ║");
  console.log("╚══════════════════════════════════════════╝\n");
  console.log("Network:", network.name);
  console.log("Oracle: ", ORACLE_ADDRESS);
  console.log("L1T:    ", L1T_ADDRESS);
  console.log("L2T:    ", L2T_ADDRESS);
  console.log("L3T:    ", L3T_ADDRESS);
  console.log("Vault:  ", VAULT_ADDRESS);
  console.log();

  const oracle = await ethers.getContractAt("EWBGorillaOracle", ORACLE_ADDRESS);

  async function ensureOracleReady() {
    try {
      await oracle.getFloorPriceETH();
      return;
    } catch (err) {
      const message = err?.reason || err?.error?.message || err?.message || "";
      if (!message.includes("Pool not set") && !message.includes("Manual floor price is stale") && !message.includes("Floor price not set")) {
        throw err;
      }
      const owner = await oracle.owner();
      if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
        throw new Error(
          `Oracle not ready and deployer is not oracle owner (${owner}). ` +
          `Set the TWAP pool or manual floor on ${ORACLE_ADDRESS} before deploying EWBTWAPConnector.`
        );
      }
      console.log("Oracle unavailable. Setting manual floor to 4.29 ETH before connector deployment...");
      await (await oracle.setManualFloor(ethers.parseEther("4.29"))).wait();
      await (await oracle.setManualFloorMaxAge(1800)).wait();
      console.log("Oracle manual floor initialized.");
    }
  }

  await ensureOracleReady();

  // Deploy connector
  console.log(">> Deploying EWBTWAPConnector...");
  const Connector = await ethers.getContractFactory("EWBTWAPConnector");
  const connector = await Connector.deploy(ORACLE_ADDRESS, VAULT_ADDRESS);
  await connector.waitForDeployment();
  const connectorAddress = await connector.getAddress();
  console.log("   Connector deployed:", connectorAddress);

  // Connect layer tokens
  console.log(">> Connecting layer tokens...");
  await (await connector.connectLayerTokens(
    L1T_ADDRESS, L2T_ADDRESS, L3T_ADDRESS
  )).wait();
  console.log("   L1T/L2T/L3T connected ✓");

  // Connect vault
  console.log(">> Connecting whale vault...");
  await (await connector.connectVault(VAULT_ADDRESS)).wait();
  console.log("   Vault connected ✓");

  // Read initial state
  const [floorETH, floorUSD, isManual, twapWindow] =
    await connector.getCurrentFloor();
  const twapStatus = await connector.getTWAPStatus();

  console.log("\n╔══════════════════════════════════════════╗");
  console.log("║           TWAP STATUS ON DEPLOY         ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log(`Floor ETH:      ${ethers.formatEther(floorETH)} ETH`);
  console.log(`Floor USD:      $${Number(floorUSD) / 1e6}`);
  console.log(`Using TWAP:     ${!isManual}`);
  console.log(`TWAP Window:    ${Number(twapWindow) / 86400} days`);
  console.log(`Manual Active:  ${isManual}`);

  console.log("\nVERIFY:");
  console.log(`npx hardhat verify --network ${network.name} ${connectorAddress} "${ORACLE_ADDRESS}"`);

  console.log("\nCONSOLE COMMANDS:");
  console.log(`const twap = await ethers.getContractAt("EWBTWAPConnector", "${connectorAddress}")`);
  console.log("await twap.getCurrentFloor()");
  console.log("await twap.getLiveLayerValues()");
  console.log("await twap.getFloorDrop()");
  console.log("await twap.getHealthStatus()");
  console.log("await twap.getTWAPStatus()");
  console.log("await twap.takeSnapshot()");

  const fs = require("fs");
  fs.mkdirSync("./deployments", { recursive: true });
  fs.writeFileSync(
    `./deployments/twap-connector-${network.name}-${Date.now()}.json`,
    JSON.stringify({
      network:   network.name,
      connector: connectorAddress,
      oracle:    ORACLE_ADDRESS,
      l1Token:   L1T_ADDRESS,
      l2Token:   L2T_ADDRESS,
      l3Token:   L3T_ADDRESS,
      vault:     VAULT_ADDRESS,
    }, null, 2)
  );
}

main().then(() => process.exit(0)).catch(e => {
  console.error(e); process.exit(1); });
