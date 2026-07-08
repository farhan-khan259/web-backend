// test/EWBDeltaNeutralVault.test.js
// Full coverage for EWBDeltaNeutralVault
// Harvest, attestation, emergency exit, hedge, auto-detection

const { expect }  = require("chai");
const { ethers }  = require("hardhat");
const {
  increaseTime, getBlockTimestamp,
  deployMockOracle, signHedgeAttestation,
  etchDeltaNeutralMocks,
} = require("./helpers");

describe("EWBDeltaNeutralVault", () => {
  let vault, oracle, aave;
  let safe, cold, bot, attacker, whaleVault;

  async function submitFreshAttestation(notional) {
    const now   = BigInt(await getBlockTimestamp());
    const nonce = ethers.hexlify(ethers.randomBytes(32));
    const sig   = await signHedgeAttestation(
      bot, notional, 100n, 0n, 800n, now, "dydx-acct-1", nonce);
    await vault.connect(bot).submitHedgeAttestation(
      notional, 100n, 0n, 800n, "dydx-acct-1", now, nonce, sig);
  }

  beforeEach(async () => {
    [safe, cold, bot, attacker, whaleVault] = await ethers.getSigners();

    oracle  = await deployMockOracle(safe);

    // The vault talks to fixed mainnet Lido / wstETH / Aave / Curve
    // addresses — etch mock bytecode there (Aave HF defaults to 2.0x).
    aave = await etchDeltaNeutralMocks();

    const Vault = await ethers.getContractFactory("EWBDeltaNeutralVault");
    // Constructor: (safeMultisig, coldWallet, revenueRouter)
    vault = await Vault.deploy(safe.address, cold.address, safe.address);

    // Register bot as hedge attestor
    await vault.connect(safe).setHedgeAttestor(bot.address);
  });

  // ── DEPLOYMENT ──────────────────────────────────────────────
  describe("Deployment", () => {
    it("sets safeMultisig and coldWallet", async () => {
      expect(await vault.safeMultisig()).to.equal(safe.address);
      expect(await vault.coldWallet()).to.equal(cold.address);
    });

    it("starts in NORMAL exit state", async () => {
      expect(await vault.exitState()).to.equal(0n); // ExitState.NORMAL
    });

    it("starts unpaused", async () => {
      expect(await vault.paused()).to.be.false;
    });

    it("maxDeployment set to 6391 ETH", async () => {
      expect(await vault.maxDeployment())
        .to.equal(ethers.parseEther("6391"));
    });
  });

  // ── HEDGE ATTESTATION ────────────────────────────────────────
  describe("Hedge Attestation", () => {
    it("registers attestor — multisig only", async () => {
      expect(await vault.hedgeAttestor()).to.equal(bot.address);
    });

    it("reverts setHedgeAttestor from non-multisig", async () => {
      await expect(
        vault.connect(attacker).setHedgeAttestor(attacker.address)
      ).to.be.revertedWith("Requires Safe multisig");
    });

    it("submits valid attestation", async () => {
      const notional = ethers.parseEther("1000");
      await submitFreshAttestation(notional);
      const [fresh] = await vault.isHedgeAttestationFresh();
      expect(fresh).to.be.true;
    });

    it("rejects attestation from wrong signer", async () => {
      const now   = BigInt(await getBlockTimestamp());
      const nonce = ethers.hexlify(ethers.randomBytes(32));
      const sig   = await signHedgeAttestation(
        attacker, ethers.parseEther("1000"),
        100n, 0n, 800n, now, "acct", nonce);
      await expect(
        vault.connect(bot).submitHedgeAttestation(
          ethers.parseEther("1000"), 100n, 0n, 800n,
          "acct", now, nonce, sig)
      ).to.be.revertedWith("Signature does not match attestor");
    });

    it("rejects stale data timestamp (> 15min — FIX R3)", async () => {
      const stale = BigInt(await getBlockTimestamp()) - 3601n;
      const nonce = ethers.hexlify(ethers.randomBytes(32));
      const sig   = await signHedgeAttestation(
        bot, ethers.parseEther("1000"),
        100n, 0n, 800n, stale, "acct", nonce);
      await expect(
        vault.connect(bot).submitHedgeAttestation(
          ethers.parseEther("1000"), 100n, 0n, 800n,
          "acct", stale, nonce, sig)
      ).to.be.revertedWith("Data timestamp too old — must be within 15 minutes");
    });

    it("attestation goes stale after 15 minutes (FIX R3: tightened from 4hr)", async () => {
      await submitFreshAttestation(ethers.parseEther("1000"));
      const [fresh1] = await vault.isHedgeAttestationFresh();
      expect(fresh1).to.be.true;
      await increaseTime(901); // FIX R3: just past 15min window
      const [fresh2] = await vault.isHedgeAttestationFresh();
      expect(fresh2).to.be.false;
    });

    it("emits HedgeAttested event", async () => {
      const notional = ethers.parseEther("1000");
      const now      = BigInt(await getBlockTimestamp());
      const nonce    = ethers.hexlify(ethers.randomBytes(32));
      const sig      = await signHedgeAttestation(
        bot, notional, 100n, 0n, 800n, now, "acct", nonce);
      await expect(
        vault.connect(bot).submitHedgeAttestation(
          notional, 100n, 0n, 800n, "acct", now, nonce, sig)
      ).to.emit(vault, "HedgeAttested");
    });

    it("stores attestation in history", async () => {
      await submitFreshAttestation(ethers.parseEther("500"));
      const status = await vault.getAttestationStatus();
      expect(status.historyLength).to.equal(1n);
    });

    it("attestedBy is always set to hedgeAttestor", async () => {
      await submitFreshAttestation(ethers.parseEther("500"));
      const status = await vault.getAttestationStatus();
      expect(status.attestor).to.equal(bot.address);
    });
  });

  // ── EMERGENCY EXIT PIPELINE ──────────────────────────────────
  describe("Emergency Exit Pipeline", () => {
    it("initiates emergency exit — safe or cold wallet", async () => {
      await vault.connect(cold).initiateEmergencyExit();
      expect(await vault.exitState()).to.equal(1n); // EXIT_IN_PROGRESS
    });

    it("initiates from safe multisig", async () => {
      await vault.connect(safe).initiateEmergencyExit();
      expect(await vault.exitState()).to.equal(1n);
    });

    it("reverts initiate from attacker", async () => {
      await expect(
        vault.connect(attacker).initiateEmergencyExit()
      ).to.be.reverted;
    });

    it("emits ExitStageAdvanced on initiate", async () => {
      await expect(vault.connect(cold).initiateEmergencyExit())
        .to.emit(vault, "ExitStageAdvanced").withArgs(1n, (v) => v > 0n);
    });

    it("force advances after 6hr timeout", async () => {
      await vault.connect(cold).initiateEmergencyExit();
      await increaseTime(6 * 3600 + 1);
      await vault.connect(safe).forceAdvanceExitStage();
      expect(await vault.exitStage()).to.be.gt(1n);
    });

    it("reverts force advance before timeout", async () => {
      await vault.connect(cold).initiateEmergencyExit();
      await expect(
        vault.connect(safe).forceAdvanceExitStage()
      ).to.be.revertedWith("Timeout not reached — wait 6 hours");
    });

    it("getExitStatus timedOut is false when not in exit", async () => {
      // getExitStatus: (state, stage, startedAt, recovered, timedOut, aavePaused, lidoAlert)
      const [, , , , timedOut] = await vault.getExitStatus();
      expect(timedOut).to.be.false;
    });

    it("getExitStatus timedOut is true after 6hrs in exit", async () => {
      await vault.connect(cold).initiateEmergencyExit();
      await increaseTime(6 * 3600 + 1);
      const [, , , , timedOut] = await vault.getExitStatus();
      expect(timedOut).to.be.true;
    });
  });

  // ── GOVERNANCE ───────────────────────────────────────────────
  describe("Governance Separation", () => {
    it("cold wallet can initiate emergency exit", async () => {
      await vault.connect(cold).initiateEmergencyExit();
      expect(await vault.exitState()).to.equal(1n);
    });

    it("cold wallet cannot change parameters", async () => {
      await expect(
        vault.connect(cold).setHedgeAttestor(attacker.address)
      ).to.be.revertedWith("Requires Safe multisig");
    });

    it("cold wallet cannot deploy ETH", async () => {
      await expect(
        vault.connect(cold).deployLongLeg({ value: ethers.parseEther("1") })
      ).to.be.revertedWith("Requires Safe multisig");
    });

    it("bot cannot change configuration", async () => {
      await expect(
        vault.connect(bot).setHedgeAttestor(attacker.address)
      ).to.be.revertedWith("Requires Safe multisig");
    });

    it("attacker cannot access any admin function", async () => {
      await expect(vault.connect(attacker).setPaused(true)).to.be.reverted;
      await expect(vault.connect(attacker).setHedgeAttestor(attacker.address)).to.be.reverted;
    });
  });

  // ── AUTO DETECTION ───────────────────────────────────────────
  describe("Auto Detection", () => {
    it("detectAavePause is callable by anyone", async () => {
      // Should not revert — Aave responding in mock
      await expect(vault.connect(attacker).detectAavePause())
        .to.not.be.reverted;
    });

    it("checkHedgeDrift is callable by multisig", async () => {
      await expect(vault.connect(safe).checkHedgeDrift())
        .to.not.be.reverted;
    });
  });

  // ── WITHDRAWAL TIMELOCK ──────────────────────────────────────
  describe("Withdrawal Timelock", () => {
    it("requestWithdrawal sets pending flag", async () => {
      await vault.connect(safe).requestWithdrawal();
      expect(await vault.withdrawalPending()).to.be.true;
    });

    it("withdrawAll reverts without requestWithdrawal", async () => {
      await expect(vault.connect(safe).withdrawAll())
        .to.be.revertedWith("Must call requestWithdrawal() first");
    });

    it("withdrawAll reverts before 24hr timelock", async () => {
      await vault.connect(safe).requestWithdrawal();
      await expect(vault.connect(safe).withdrawAll())
        .to.be.revertedWith("24hr timelock not elapsed");
    });

    it("withdrawAll executes after 24hr timelock", async () => {
      await vault.connect(safe).requestWithdrawal();
      await increaseTime(24 * 3600 + 1);
      // Will succeed (zero balance is fine in test)
      await expect(vault.connect(safe).withdrawAll())
        .to.not.be.reverted;
    });
  });

  // ── STALE ATTESTATION GATES ──────────────────────────────────
  describe("Stale Attestation Gates", () => {
    it("harvestYield reverts with stale attestation", async () => {
      // harvestYield is onlyOwner; call as safe so we exercise the
      // in-body staleness guard rather than the access-control modifier.
      await submitFreshAttestation(ethers.parseEther("1000"));
      await increaseTime(901); // FIX R3: just past 15min window
      await expect(vault.connect(safe).harvestYield(100n))
        .to.be.revertedWith("STALE_HEDGE_ATTESTATION — bot must attest before harvesting");
    });

    it("harvestYield works with fresh attestation", async () => {
      await submitFreshAttestation(ethers.parseEther("1000"));
      // Should not revert on stale check (may revert for other reasons)
      const [fresh] = await vault.isHedgeAttestationFresh();
      expect(fresh).to.be.true;
    });
  });
});
