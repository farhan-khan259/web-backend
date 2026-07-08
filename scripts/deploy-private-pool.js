/**
 * deploy-private-pool.js
 *
 * Deploys EWBPrivatePool + EWBPrivateHarvest and wires both
 * to your existing EWBWhaleVault.
 *
 * PREREQUISITES (must already be deployed):
 *   - EWBWhaleVault
 *   - EWBMintingRightsVault  (read for LTV reference only)
 *
 * Both addresses are read from .env — never hard-coded.
 *
 * USAGE:
 *   npx hardhat run scripts/deploy-private-pool.js --network sepolia
 *   npx hardhat run scripts/deploy-private-pool.js --network mainnet
 *
 * POST-DEPLOY CHECKLIST (Safe multisig required):
 *   □ EWBPrivatePool:    addToWhitelist(partyA)
 *   □ EWBPrivatePool:    addToWhitelist(partyB)
 *   □ EWBPrivateHarvest: setHarvesterKey(HARVESTER_BOT_ADDRESS)
 *   □ EWBPrivateHarvest: addHarvester(partyA)
 *   □ EWBPrivateHarvest: addHarvester(partyB)
 *   □ Set HARVEST_CONTRACT_ADDRESS + PRIVATE_POOL_ADDRESS in .env
 *   □ Run harvestBot.js to begin harvest cycle
 */

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ----------------------------------------------------------------
// VALIDATION HELPERS
// ----------------------------------------------------------------

function requireEnv(key) {
    const val = process.env[key];
    if (!val || val.trim() === "") {
        throw new Error(
            `\n  ❌  Missing required .env variable: ${key}\n` +
            `     Add it to your .env file before deploying.\n`
        );
    }
    return val.trim();
}

function isValidAddress(addr) {
    try {
        ethers.getAddress(addr);
        return true;
    } catch {
        return false;
    }
}

function validateAddresses(map) {
    for (const [key, addr] of Object.entries(map)) {
        if (!isValidAddress(addr)) {
            throw new Error(
                `\n  ❌  Invalid address for ${key}: "${addr}"\n` +
                `     Check your .env file.\n`
            );
        }
    }
}

// ----------------------------------------------------------------
// MAIN
// ----------------------------------------------------------------

async function main() {
    const [deployer] = await ethers.getSigners();
    const net        = await ethers.provider.getNetwork();
    const isMainnet  = net.chainId === 1n;
    const networkName = network.name;

    console.log("\n═══════════════════════════════════════════════════");
    console.log(" EWB Private Pool + Harvest — Deploy Script");
    console.log("═══════════════════════════════════════════════════");
    console.log(` Network:   ${networkName} (chainId: ${net.chainId})`);
    console.log(` Deployer:  ${deployer.address}`);
    console.log(` Balance:   ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);
    console.log("═══════════════════════════════════════════════════\n");

    // ── Load and validate .env addresses ─────────────────────────

    const SAFE_MULTISIG        = requireEnv("SAFE_MULTISIG");
    const COLD_WALLET          = requireEnv("COLD_WALLET");
    const WHALE_VAULT_ADDRESS  = requireEnv("WHALE_VAULT_ADDRESS");
    const HARVESTER_BOT_ADDRESS = requireEnv("HARVESTER_BOT_ADDRESS");

    validateAddresses({
        SAFE_MULTISIG,
        COLD_WALLET,
        WHALE_VAULT_ADDRESS,
        HARVESTER_BOT_ADDRESS,
    });

    // ── Safety gate for mainnet ───────────────────────────────────

    if (isMainnet) {
        console.log("⚠️  MAINNET DEPLOYMENT DETECTED");
        console.log("   Pausing 10 seconds — press Ctrl+C to abort.\n");
        await new Promise(r => setTimeout(r, 10_000));
    }

    // ── 1. Deploy EWBPrivatePool ──────────────────────────────────

    console.log("Deploying EWBPrivatePool...");
    console.log(`  safeMultisig: ${SAFE_MULTISIG}`);
    console.log(`  coldWallet:   ${COLD_WALLET}`);
    console.log(`  whaleVault:   ${WHALE_VAULT_ADDRESS}\n`);

    const PoolFactory = await ethers.getContractFactory("EWBPrivatePool");
    const pool = await PoolFactory.deploy(
        SAFE_MULTISIG,
        COLD_WALLET,
        WHALE_VAULT_ADDRESS
    );
    await pool.waitForDeployment();
    const poolAddr = await pool.getAddress();

    console.log(`✅  EWBPrivatePool deployed: ${poolAddr}\n`);

    // ── 2. Deploy EWBPrivateHarvest ───────────────────────────────

    console.log("Deploying EWBPrivateHarvest...");
    console.log(`  safeMultisig: ${SAFE_MULTISIG}`);
    console.log(`  coldWallet:   ${COLD_WALLET}`);
    console.log(`  whaleVault:   ${WHALE_VAULT_ADDRESS}\n`);

    const HarvestFactory = await ethers.getContractFactory("EWBPrivateHarvest");
    const harvest = await HarvestFactory.deploy(
        SAFE_MULTISIG,
        COLD_WALLET,
        WHALE_VAULT_ADDRESS
    );
    await harvest.waitForDeployment();
    const harvestAddr = await harvest.getAddress();

    console.log(`✅  EWBPrivateHarvest deployed: ${harvestAddr}\n`);

    // ── 3. Verify constructor args wired correctly ────────────────

    console.log("Verifying wiring...");

    const poolMultisig  = await pool.safeMultisig();
    const poolVault     = await pool.whaleVault();
    const harvestVault  = await harvest.whaleVault();
    const harvestMultisig = await harvest.safeMultisig();

    const wiringOk =
        poolMultisig.toLowerCase()    === SAFE_MULTISIG.toLowerCase()    &&
        poolVault.toLowerCase()        === WHALE_VAULT_ADDRESS.toLowerCase() &&
        harvestVault.toLowerCase()     === WHALE_VAULT_ADDRESS.toLowerCase() &&
        harvestMultisig.toLowerCase()  === SAFE_MULTISIG.toLowerCase();

    if (!wiringOk) {
        throw new Error("❌  Wiring verification failed — constructor args mismatch");
    }

    console.log("✅  All constructor args verified on-chain\n");

    // ── 4. Save deployment manifest ───────────────────────────────

    const timestamp = Date.now();
    const manifest  = {
        network:         networkName,
        chainId:         net.chainId.toString(),
        deployedAt:      new Date(timestamp).toISOString(),
        deployer:        deployer.address,
        contracts: {
            EWBPrivatePool: {
                address:      poolAddr,
                constructorArgs: [SAFE_MULTISIG, COLD_WALLET, WHALE_VAULT_ADDRESS],
            },
            EWBPrivateHarvest: {
                address:      harvestAddr,
                constructorArgs: [SAFE_MULTISIG, COLD_WALLET, WHALE_VAULT_ADDRESS],
            },
        },
        existing: {
            EWBWhaleVault:         WHALE_VAULT_ADDRESS,
            harvesterBotAddress:   HARVESTER_BOT_ADDRESS,
        },
    };

    const deploymentsDir = path.join(__dirname, "..", "deployments");
    fs.mkdirSync(deploymentsDir, { recursive: true });

    const manifestPath = path.join(
        deploymentsDir,
        `${networkName}-private-pool-${timestamp}.json`
    );
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`📄  Deployment manifest saved: ${manifestPath}\n`);

    // ── 5. Print summary ──────────────────────────────────────────

    console.log("═══════════════════════════════════════════════════");
    console.log(" DEPLOYMENT COMPLETE");
    console.log("═══════════════════════════════════════════════════");
    console.log(` EWBPrivatePool:    ${poolAddr}`);
    console.log(` EWBPrivateHarvest: ${harvestAddr}`);
    console.log("───────────────────────────────────────────────────\n");

    // ── 6. Etherscan verify commands ──────────────────────────────

    console.log("VERIFY ON ETHERSCAN (run after deployment):\n");
    console.log(
        `npx hardhat verify --network ${networkName} ${poolAddr} ` +
        `"${SAFE_MULTISIG}" "${COLD_WALLET}" "${WHALE_VAULT_ADDRESS}"`
    );
    console.log(
        `npx hardhat verify --network ${networkName} ${harvestAddr} ` +
        `"${SAFE_MULTISIG}" "${COLD_WALLET}" "${WHALE_VAULT_ADDRESS}"\n`
    );

    // ── 7. Post-deploy multisig checklist ─────────────────────────

    console.log("═══════════════════════════════════════════════════");
    console.log(" POST-DEPLOY CHECKLIST — Safe Multisig Required");
    console.log("═══════════════════════════════════════════════════");
    console.log(`
 EWBPrivateHarvest (${harvestAddr}):
   1. setHarvesterKey("${HARVESTER_BOT_ADDRESS}")
      → One-time. Cannot be changed after set.

   2. addHarvester("<partyA_address>")
   3. addHarvester("<partyB_address>")

 EWBPrivatePool (${poolAddr}):
   4. addToWhitelist("<partyA_address>")
   5. addToWhitelist("<partyB_address>")
   6. createPool(partyA, partyB, ltv, deadlineSec, secretHash)
      → ltv example: 800 = 8%
      → deadlineSec example: 2592000 = 30 days
      → secretHash: ethers.keccak256(ethers.toUtf8Bytes("your-secret"))
        or bytes32(0) to skip

   7. seedPool(poolId, 0, lockIdA)   ← Side A (your NFTs)
   8. seedPool(poolId, 1, lockIdB)   ← Side B (your NFTs)
      → Pool transitions to OPEN automatically when both seeded

 .env (update after deployment):
   PRIVATE_POOL_ADDRESS=${poolAddr}
   HARVEST_CONTRACT_ADDRESS=${harvestAddr}

 harvestBot.js:
   9. Set lockIds in config to your WhaleVault lock IDs
  10. Run: node scripts/harvestBot.js
`);
    console.log("═══════════════════════════════════════════════════\n");
}

main()
    .then(() => process.exit(0))
    .catch(err => {
        console.error("\n❌  Deploy failed:\n", err.message || err);
        process.exit(1);
    });
