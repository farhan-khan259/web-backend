/**
 * EWB Vault — Bytecode Hash Verification
 *
 * Run after compilation to generate bytecode hashes.
 * Compare against known-good hashes before mainnet deployment.
 * If any hash differs — deployment is INVALID.
 *
 * Usage:
 *   npm run build:reproducible   # Clean compile
 *   node scripts/verify-bytecode.js  # Generate + compare hashes
 *
 * Output saved to: bytecode-hashes.json
 * Compare this file against the audit firm's verified hashes.
 */

const { ethers } = require("ethers");
const fs   = require("fs");
const path = require("path");

// ── PHASE 1 CONTRACTS TO VERIFY ──────────────────────────────
const CONTRACTS = [
    "EWBWhaleVault",
    "EWBGorillaOracle",
    "EWBDeltaNeutralVault",
    "EWBDevPayment",
];

// ── KNOWN GOOD HASHES (fill after first clean audit build) ───
// These are set by the audit firm after certification.
// Any deviation from these = deployment is invalid.
const KNOWN_GOOD_HASHES = {
    // "EWBWhaleVault":        "0x...",  // Set after audit
    // "EWBGorillaOracle":     "0x...",  // Set after audit
    // "EWBDeltaNeutralVault": "0x...",  // Set after audit
    // "EWBDevPayment":        "0x...",  // Set after audit
};

function getArtifact(contractName) {
    const artifactPath = path.join(
        __dirname, "..", "artifacts", "contracts",
        `${contractName}.sol`, `${contractName}.json`
    );
    if (!fs.existsSync(artifactPath)) {
        throw new Error(`Artifact not found: ${artifactPath}\nRun: npm run build:reproducible`);
    }
    return JSON.parse(fs.readFileSync(artifactPath, "utf8"));
}

async function main() {
    console.log("EWB Vault — Bytecode Hash Verification");
    console.log("========================================\n");

    const results = {};
    let allMatch  = true;
    let hasKnownGood = Object.keys(KNOWN_GOOD_HASHES).length > 0;

    for (const name of CONTRACTS) {
        const artifact   = getArtifact(name);
        const bytecode   = artifact.bytecode;
        const deployedBc = artifact.deployedBytecode;

        // Hash both creation bytecode and deployed bytecode
        const creationHash = ethers.keccak256(ethers.toUtf8Bytes(bytecode));
        const deployedHash = ethers.keccak256(ethers.toUtf8Bytes(deployedBc));

        results[name] = {
            creationBytecodeHash: creationHash,
            deployedBytecodeHash: deployedHash,
            sourceFile:           `contracts/${name}.sol`,
            compiler:             artifact.metadata
                ? JSON.parse(artifact.metadata).compiler?.version || "unknown"
                : "unknown",
        };

        // Compare against known good if set
        const known = KNOWN_GOOD_HASHES[name];
        let status = "NEW (no known-good hash set)";

        if (known) {
            if (creationHash === known) {
                status = "✓ MATCH — bytecode verified";
            } else {
                status = "✗ MISMATCH — DEPLOYMENT INVALID";
                allMatch = false;
            }
        }

        console.log(`${name}`);
        console.log(`  Creation:  ${creationHash}`);
        console.log(`  Deployed:  ${deployedHash}`);
        console.log(`  Status:    ${status}\n`);
    }

    // Save hashes
    const output = {
        generatedAt:    new Date().toISOString(),
        networkTarget:  "Ethereum Mainnet",
        solcVersion:    "0.8.19",
        contracts:      results,
        verified:       hasKnownGood ? allMatch : null,
        instructions: [
            "1. Run: npm run build:reproducible",
            "2. Run: node scripts/verify-bytecode.js",
            "3. Send bytecode-hashes.json to audit firm",
            "4. Audit firm confirms hashes match their build",
            "5. Paste audit firm's hashes into KNOWN_GOOD_HASHES above",
            "6. Re-run — all must show MATCH before mainnet deploy",
        ],
    };

    fs.writeFileSync(
        path.join(__dirname, "..", "bytecode-hashes.json"),
        JSON.stringify(output, null, 2)
    );

    console.log("Hashes saved to: bytecode-hashes.json");

    if (hasKnownGood && !allMatch) {
        console.error("\n⚠️  BYTECODE MISMATCH DETECTED — DO NOT DEPLOY TO MAINNET");
        process.exit(1);
    } else if (!hasKnownGood) {
        console.log("\nℹ️  No known-good hashes set yet.");
        console.log("   Send bytecode-hashes.json to audit firm.");
        console.log("   Paste their verified hashes into KNOWN_GOOD_HASHES.");
    } else {
        console.log("\n✓ All bytecodes match known-good hashes. Safe to deploy.");
    }
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
