/**
 * EWB Private Harvest Bot — harvestBot.js
 *
 * Reads token IDs from EWBWhaleVault, builds and signs harvest proofs,
 * submits requests to EWBPrivateHarvest on-chain.
 *
 * NO ETH FLOWS THROUGH THIS BOT — only identity proofs and gas fees.
 *
 * FLOW:
 *   1. Read locked token IDs from EWBWhaleVault (view call — free)
 *   2. Build: keccak256("EWB_HARVEST_V1", harvester, keccak256(tokenIds[]),
 *             timestamp, nonce)
 *   3. Sign with harvesterKey private key
 *   4. Submit submitHarvestRequest() — verified on-chain
 *   5. Multisig calls confirmHarvest(requestId, creditPerToken)
 *
 * SECURITY FIXES APPLIED:
 *   - Single canonical BigInt[] array used for both signing and submission
 *     (eliminates P1-14 divergence risk)
 *   - Number(req.state) cast before array index (fixes P1-15 BigInt bug)
 *   - Per-lock cooldown prevents duplicate submission in same cycle (P1-16)
 *   - harvesterAddress always sourced from config, never caller-supplied
 */

const { ethers } = require("ethers");
const crypto = require("crypto");

// ----------------------------------------------------------------
// ABIs — minimal: only functions this bot calls
// ----------------------------------------------------------------

const WHALE_VAULT_ABI = [
    "function isMintingRightLocked(uint256 tokenId) external view returns (bool)",
    "function getMintingLock(uint256 lockId) external view returns (" +
        "uint256[] tokenIds, uint256 faceValueETH, uint256 faceValueUSD, " +
        "uint256 lockedAt, uint256 expiresAt, bool active, string purpose)",
];

const HARVEST_ABI = [
    "function submitHarvestRequest(uint256[] tokenIds, uint256 sigTimestamp, bytes32 nonce, bytes signature) external returns (uint256 requestId)",
    "function harvesterKey() external view returns (address)",
    "function isNonceUsed(address harvester, bytes32 nonce) external view returns (bool)",
    "function harvestWhitelist(address) external view returns (bool)",
    "function getRequest(uint256 requestId) external view returns (" +
        "address harvester, uint256[] tokenIds, uint256 submittedAt, " +
        "uint256 expiresAt, uint256 sigTimestamp, uint8 state, uint256 creditAwarded)",
    "function getCreditBalance(address harvester) external view returns (uint256)",
];

const DELTA_VAULT_ABI = [
    "function compoundYield(uint256 compoundAmount) external",
    "function getAccruedYield() external view returns (uint256)",
    "function totalDeployed() external view returns (uint256)",
    "function maxDeployment() external view returns (uint256)",
];

// ----------------------------------------------------------------
// CONSTANTS
// ----------------------------------------------------------------

const REQUEST_STATE = ["PENDING", "CONFIRMED", "REJECTED"]; // index matches enum

/** Minimum seconds between submissions for the same lockId */
const SUBMISSION_COOLDOWN_SEC = 3600; // 1 hour

// ----------------------------------------------------------------
// HarvestBot
// ----------------------------------------------------------------

class HarvestBot {
    /**
     * @param {ethers.JsonRpcProvider} provider
     * @param {ethers.Wallet}          botWallet       — the harvesterKey wallet
     * @param {string}                 whaleVaultAddr  — EWBWhaleVault address
     * @param {string}                 harvestAddr     — EWBPrivateHarvest address
     * @param {object}                 config
     * @param {number[]}               config.lockIds          — WhaleVault lock IDs
     * @param {string}                 config.harvesterAddress — whitelisted submitter
     * @param {object}                 log             — logger (console or winston)
     */
    constructor(provider, botWallet, whaleVaultAddr, harvestAddr, config, log) {
        this.botWallet  = botWallet;
        this.whaleVault = new ethers.Contract(whaleVaultAddr, WHALE_VAULT_ABI, botWallet);
        this.harvest    = new ethers.Contract(harvestAddr,    HARVEST_ABI,     botWallet);
        this.deltaVault = config.deltaVaultAddr
            ? new ethers.Contract(config.deltaVaultAddr, DELTA_VAULT_ABI, botWallet)
            : null;
        this.config     = config;
        this.log        = log;

        // Per-lockId last submission timestamp — prevents duplicate submissions
        this._lastSubmitted = {};
        // Last compound timestamp
        this._lastCompounded = 0;
    }

    // ----------------------------------------------------------------
    // STEP 1 — Read locked token IDs from WhaleVault (no ETH)
    // ----------------------------------------------------------------

    /**
     * Returns confirmed lock data for all configured lockIds.
     * Each entry: { lockId, tokenIdsBigInt, faceValueUSD }
     * tokenIdsBigInt is the single canonical BigInt[] used for both
     * signing and on-chain submission — prevents P1-14 divergence.
     */
    async readLockedTokenIds() {
        const results = [];

        for (const lockId of this.config.lockIds) {
            try {
                const lock = await this.whaleVault.getMintingLock(lockId);

                if (!lock.active) {
                    this.log.warn(`Lock ${lockId}: not active — skipping`);
                    continue;
                }

                // Convert to BigInt[] once — canonical representation
                const tokenIdsBigInt = [];
                for (const tid of lock.tokenIds) {
                    const locked = await this.whaleVault.isMintingRightLocked(tid);
                    if (locked) {
                        tokenIdsBigInt.push(BigInt(tid.toString()));
                    } else {
                        this.log.warn(`Lock ${lockId}: token ${tid} not individually locked — excluding`);
                    }
                }

                if (tokenIdsBigInt.length === 0) {
                    this.log.warn(`Lock ${lockId}: no confirmed tokens — skipping`);
                    continue;
                }

                results.push({
                    lockId,
                    tokenIdsBigInt,
                    faceValueUSD: lock.faceValueUSD,
                });

                this.log.info(
                    `Lock ${lockId}: ${tokenIdsBigInt.length} token(s) confirmed | ` +
                    `faceValueUSD: $${Number(lock.faceValueUSD) / 1e6}`
                );
            } catch (err) {
                this.log.error(`Lock ${lockId}: read failed — ${err.message}`);
            }
        }

        return results;
    }

    // ----------------------------------------------------------------
    // STEP 2 — Build and sign harvest proof
    // ----------------------------------------------------------------

    /**
     * Signs the harvest payload using the same encoding as the contract.
     *
     * Contract hash:
     *   keccak256(DOMAIN, msg.sender, keccak256(abi.encodePacked(tokenIds)), sigTimestamp, nonce)
     *
     * @param {string}   harvesterAddress  — must match msg.sender when submitted
     * @param {bigint[]} tokenIdsBigInt    — canonical array (from readLockedTokenIds)
     * @param {number}   timestamp
     * @param {string}   nonce             — 0x-prefixed bytes32 hex string
     */
    async signHarvestProof(harvesterAddress, tokenIdsBigInt, timestamp, nonce) {
        // Encode token IDs — matches abi.encodePacked(uint256[]) in contract
        const idsEncoded = ethers.solidityPacked(
            tokenIdsBigInt.map(() => "uint256"),
            tokenIdsBigInt
        );
        const idsHash = ethers.keccak256(idsEncoded);

        // Full payload hash — must match contract's dataHash exactly
        const dataHash = ethers.solidityPackedKeccak256(
            ["string", "address", "bytes32", "uint256", "bytes32"],
            ["EWB_HARVEST_V1", harvesterAddress, idsHash, timestamp, nonce]
        );

        // ethers.signMessage adds "\x19Ethereum Signed Message:\n32" prefix
        // matching the contract's _recoverSigner()
        const signature = await this.botWallet.signMessage(ethers.getBytes(dataHash));

        return signature;
    }

    // ----------------------------------------------------------------
    // STEP 3 — Submit request on-chain
    // ----------------------------------------------------------------

    /**
     * Submits a harvest request for one lock.
     * Uses the same tokenIdsBigInt array for signing and submission.
     * Enforces per-lock cooldown to prevent duplicate submissions.
     */
    async submitHarvestForLock(lockData) {
        const { lockId, tokenIdsBigInt } = lockData;
        const { harvesterAddress }       = this.config;

        // Cooldown check — prevents duplicate submissions (P1-16 fix)
        const now = Math.floor(Date.now() / 1000);
        const lastSubmit = this._lastSubmitted[lockId] || 0;
        if (now - lastSubmit < SUBMISSION_COOLDOWN_SEC) {
            this.log.info(
                `Lock ${lockId}: cooldown active (${SUBMISSION_COOLDOWN_SEC - (now - lastSubmit)}s remaining) — skipping`
            );
            return null;
        }

        // Verify bot is registered harvesterKey
        const registeredKey = await this.harvest.harvesterKey();
        if (registeredKey.toLowerCase() !== this.botWallet.address.toLowerCase()) {
            this.log.error(
                `Bot wallet ${this.botWallet.address} is not the registered harvesterKey.\n` +
                `Registered: ${registeredKey}\n` +
                `Fix: call setHarvesterKey("${this.botWallet.address}") from Safe multisig`
            );
            return null;
        }

        // Verify harvester is whitelisted
        const whitelisted = await this.harvest.harvestWhitelist(harvesterAddress);
        if (!whitelisted) {
            this.log.error(
                `${harvesterAddress} is not whitelisted.\n` +
                `Fix: call addHarvester("${harvesterAddress}") from Safe multisig`
            );
            return null;
        }

        // Generate nonce — random bytes32
        const nonce     = "0x" + crypto.randomBytes(32).toString("hex");
        const timestamp = Math.floor(Date.now() / 1000);

        // Verify nonce not used (collision probability is negligible but check anyway)
        const nonceUsed = await this.harvest.isNonceUsed(harvesterAddress, nonce);
        if (nonceUsed) {
            this.log.warn(`Nonce already used for lock ${lockId} — regenerate and retry`);
            return null;
        }

        // Sign using the canonical tokenIdsBigInt array
        const signature = await this.signHarvestProof(
            harvesterAddress,
            tokenIdsBigInt,
            timestamp,
            nonce
        );

        this.log.info(
            `Lock ${lockId}: submitting ${tokenIdsBigInt.length} token(s) | ts: ${timestamp}`
        );

        try {
            // Submit — same tokenIdsBigInt array used for signing and submission (P1-14 fix)
            const tx = await this.harvest.submitHarvestRequest(
                tokenIdsBigInt,
                timestamp,
                nonce,
                signature,
                { gasLimit: 400_000 }
            );

            const receipt = await tx.wait();

            // Parse requestId from event log
            let requestId = null;
            for (const log of receipt.logs) {
                try {
                    const parsed = this.harvest.interface.parseLog(log);
                    if (parsed?.name === "HarvestRequestSubmitted") {
                        requestId = parsed.args.requestId.toString();
                    }
                } catch { /* non-matching log */ }
            }

            // Update cooldown timestamp on success
            this._lastSubmitted[lockId] = now;

            this.log.info(
                `Lock ${lockId}: request submitted — requestId=${requestId} | tx=${tx.hash}`
            );

            return { requestId, txHash: tx.hash };
        } catch (err) {
            this.log.error(`Lock ${lockId}: submitHarvestRequest failed — ${err.message}`);
            return null;
        }
    }

    // ----------------------------------------------------------------
    // MAIN CYCLE
    // ----------------------------------------------------------------

    /**
     * Compound accrued yield back into the Aave position.
     * Calls compoundYield() on EWBDeltaNeutralVault.
     * Runs once per 7 days. Zero new ETH required.
     * Rebase yield is already in Aave — just updates totalDeployed.
     */
    async compoundIfReady() {
        if (!this.deltaVault) return null;

        const COMPOUND_INTERVAL = 7 * 24 * 3600; // 7 days
        const MIN_COMPOUND      = ethers.parseEther("0.01");
        const now               = Math.floor(Date.now() / 1000);

        if (now - this._lastCompounded < COMPOUND_INTERVAL) {
            const hrs = Math.round((COMPOUND_INTERVAL - (now - this._lastCompounded)) / 3600);
            this.log.info(`Compound cooldown: ${hrs}hrs remaining`);
            return null;
        }

        try {
            const accrued   = await this.deltaVault.getAccruedYield();
            const deployed  = await this.deltaVault.totalDeployed();
            const maxDep    = await this.deltaVault.maxDeployment();
            const headroom  = maxDep - deployed;
            const amount    = accrued < headroom ? accrued : headroom;

            if (amount < MIN_COMPOUND) {
                this.log.info(`Compound skipped: ${ethers.formatEther(accrued)} ETH below minimum`);
                return null;
            }

            this.log.info(`Compounding ${ethers.formatEther(amount)} ETH`);
            const tx = await this.deltaVault.compoundYield(amount, { gasLimit: 120_000 });
            await tx.wait();
            this._lastCompounded = now;
            this.log.info(`Compound confirmed: tx=${tx.hash}`);
            return { compounded: ethers.formatEther(amount), txHash: tx.hash };
        } catch (err) {
            this.log.error(`compoundYield failed: ${err.message}`);
            return null;
        }
    }

    /**
     * Run one full harvest cycle.
     * Returns array of { lockId, requestId, txHash } for successful submissions.
     */
    async runHarvestCycle() {
        this.log.info("=== EWB Harvest Cycle: start ===");

        // Attempt compound first — weekly, zero ETH, no dynamic change
        await this.compoundIfReady();

        const lockData = await this.readLockedTokenIds();

        if (lockData.length === 0) {
            this.log.warn("No active locks found — nothing to harvest");
            return [];
        }

        const results = [];
        for (const lock of lockData) {
            const result = await this.submitHarvestForLock(lock);
            if (result) results.push({ lockId: lock.lockId, ...result });
        }

        this.log.info(
            `=== EWB Harvest Cycle: ${results.length}/${lockData.length} submitted ===`
        );

        return results;
    }

    // ----------------------------------------------------------------
    // MONITORING
    // ----------------------------------------------------------------

    /**
     * Check status of specific requestIds and credit balance.
     * Safe to call at any time — read-only.
     *
     * @param {string[]} requestIds — requestId strings to check
     */
    async checkStatus(requestIds) {
        const { harvesterAddress } = this.config;

        try {
            const credit = await this.harvest.getCreditBalance(harvesterAddress);
            this.log.info(
                `Credit balance [${harvesterAddress}]: ${Number(credit) / 1e6} units`
            );
        } catch (err) {
            this.log.error(`Could not read credit balance: ${err.message}`);
        }

        for (const reqId of requestIds) {
            try {
                const req = await this.harvest.getRequest(reqId);
                // P1-15 fix: Number() cast before using BigInt as array index
                const stateLabel = REQUEST_STATE[Number(req.state)] ?? "UNKNOWN";
                this.log.info(
                    `Request ${reqId}: ${stateLabel} | ` +
                    `tokens=${req.tokenIds.length} | ` +
                    `credit=${Number(req.creditAwarded) / 1e6} | ` +
                    `expires=${new Date(Number(req.expiresAt) * 1000).toISOString()}`
                );
            } catch (err) {
                this.log.error(`Request ${reqId}: read failed — ${err.message}`);
            }
        }
    }
}

// ----------------------------------------------------------------
// USAGE
// ----------------------------------------------------------------

/*
const provider  = new ethers.JsonRpcProvider(process.env.RPC_URL);
const botWallet = new ethers.Wallet(process.env.HARVESTER_PRIVATE_KEY, provider);

const bot = new HarvestBot(
    provider,
    botWallet,
    process.env.WHALE_VAULT_ADDRESS,
    process.env.HARVEST_CONTRACT_ADDRESS,
    {
        lockIds:          [1, 2],
        harvesterAddress: process.env.HARVESTER_ADDRESS,
    },
    console
);

// Run once:
bot.runHarvestCycle().then(results => {
    console.log("Submitted:", results);
    // Multisig calls confirmHarvest(requestId, creditPerToken) for each
});

// Or on a schedule (every 4 hours):
setInterval(() => bot.runHarvestCycle(), 4 * 60 * 60 * 1000);
*/

module.exports = { HarvestBot };
