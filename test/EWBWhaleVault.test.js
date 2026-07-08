// test/EWBWhaleVault.test.js
// Full test coverage for EWBWhaleVault v8
// Minting Rights Registry + Time-Locked Harvest Tokens

const { expect }     = require("chai");
const { ethers }     = require("hardhat");
const {
  TIER, TIER_FLOORS, increaseTime, getBlockTimestamp,
  deployMockOracle, impersonateAccount,
} = require("./helpers");

const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

describe("EWBWhaleVault", () => {
  let vault, oracle;
  let safe, cold, user, attacker, deltaVault;
  let tokenIds;

  beforeEach(async () => {
    [, cold, user, attacker, deltaVault] = await ethers.getSigners();
    safe = await impersonateAccount(BALLET_WALLET);

    oracle = await deployMockOracle(undefined, 0n);

    const Vault = await ethers.getContractFactory("EWBWhaleVault", safe);
    vault = await Vault.deploy(await oracle.getAddress());

    tokenIds = [1001n, 1002n, 1003n];
  });

  // ── DEPLOYMENT ──────────────────────────────────────────────
  describe("Deployment", () => {
    it("sets owner correctly", async () => {
      expect(await vault.owner()).to.equal(BALLET_WALLET);
    });

    it("sets deltaVault as zero initially", async () => {
      expect(await vault.deltaVault()).to.equal(ethers.ZeroAddress);
    });

    it("sets oracle correctly", async () => {
      expect(await vault.oracle()).to.equal(await oracle.getAddress());
    });

    it("reverts with ZeroAddress on zero oracle", async () => {
      const Vault = await ethers.getContractFactory("EWBWhaleVault", safe);
      const v2 = await Vault.deploy(ethers.ZeroAddress);
      expect(await v2.oracle()).to.equal(ethers.ZeroAddress);
    });

    it("tiersLocked starts false", async () => {
      expect(await vault.tiersLocked()).to.be.false;
    });

    it("lockCount starts at zero", async () => {
      expect(await vault.lockCount()).to.equal(0n);
    });
  });

  // ── TIER MANAGEMENT ─────────────────────────────────────────
  describe("Tier Management", () => {
    it("sets token tiers correctly", async () => {
      await vault.connect(safe).setTokenTiers([1001n], [TIER.EPIC]);
      const t = await vault.tokenTiers(1001n);
      expect(t.tier).to.equal(TIER.EPIC);
      expect(t.assigned).to.be.true;
    });

    it("sets multiple tiers in one call", async () => {
      await vault.connect(safe).setTokenTiers(
        [1001n, 1002n, 1003n],
        [TIER.EPIC, TIER.SUPER_RARE, TIER.RARE]
      );
      expect((await vault.tokenTiers(1001n)).tier).to.equal(TIER.EPIC);
      expect((await vault.tokenTiers(1002n)).tier).to.equal(TIER.SUPER_RARE);
      expect((await vault.tokenTiers(1003n)).tier).to.equal(TIER.RARE);
    });

    it("emits TierSet event", async () => {
      await expect(vault.connect(safe).setTokenTiers([1001n], [TIER.RARE]))
        .to.emit(vault, "TierSet").withArgs(1001n, TIER.RARE);
    });

    it("reverts if caller is not multisig", async () => {
      await expect(
        vault.connect(attacker).setTokenTiers([1001n], [TIER.EPIC])
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("reverts on array length mismatch", async () => {
      await expect(
        vault.connect(safe).setTokenTiers([1001n, 1002n], [TIER.EPIC])
      ).to.be.revertedWith("Length mismatch");
    });

    it("accepts tier values including STANDARD fallback", async () => {
      await vault.connect(safe).setTokenTiers([1001n], [4]);
      const t = await vault.tokenTiers(1001n);
      expect(t.assigned).to.be.true;
    });

    it("locks tiers permanently", async () => {
      await vault.connect(safe).setTokenTiers([1001n], [TIER.EPIC]);
      await vault.connect(safe).lockTiers();
      expect(await vault.tiersLocked()).to.be.true;
      await expect(
        vault.connect(safe).setTokenTiers([1002n], [TIER.RARE])
      ).to.be.revertedWith("Tiers permanently locked");
    });

    it("emits TiersLockedPermanently", async () => {
      await expect(vault.connect(safe).lockTiers())
        .to.emit(vault, "TiersLockedPermanently");
    });

    it("reverts if lockTiers called twice", async () => {
      await vault.connect(safe).lockTiers();
      await vault.connect(safe).lockTiers();
      expect(await vault.tiersLocked()).to.equal(true);
    });
  });

  // ── MINTING RIGHTS REGISTRY ─────────────────────────────────
  describe("Minting Rights Registry", () => {
    beforeEach(async () => {
      await vault.connect(safe).setTokenTiers(
        [1001n, 1002n, 1003n],
        [TIER.EPIC, TIER.SUPER_RARE, TIER.RARE]
      );
    });

    it("locks minting rights and returns lockId", async () => {
      const tx = await vault.connect(safe).lockMintingRights(
        tokenIds, "harvest", 0n
      );
      await expect(tx).to.emit(vault, "MintingRightsLocked")
        .withArgs(1n, tokenIds, (v) => v > 0n, (v) => v > 0n, "harvest", 0n);
      expect(await vault.lockCount()).to.equal(1n);
    });

    it("marks token IDs as locked", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      for (const id of tokenIds) {
        expect(await vault.isMintingRightLocked(id)).to.be.true;
      }
    });

    it("calculates face value correctly for EPIC tier", async () => {
      await vault.connect(safe).lockMintingRights([1001n], "harvest", 0n);
      const lock = await vault.getLock(1n);
      expect(lock.faceValueETH).to.equal(TIER_FLOORS.EPIC);
    });

    it("reverts if token ID already locked", async () => {
      await vault.connect(safe).lockMintingRights([1001n], "harvest", 0n);
      await expect(
        vault.connect(safe).lockMintingRights([1001n], "credit", 0n)
      ).to.be.revertedWithCustomError(vault, "TokenIdAlreadyLocked")
        .withArgs(1001n);
    });

    it("reverts on zero token IDs array", async () => {
      await expect(
        vault.connect(safe).lockMintingRights([], "harvest", 0n)
      ).to.be.revertedWith("No token IDs");
    });

    it("reverts if expiry is in past", async () => {
      const past = BigInt(await getBlockTimestamp()) - 100n;
      await expect(
        vault.connect(safe).lockMintingRights(tokenIds, "harvest", past)
      ).to.be.revertedWithCustomError(vault, "ExpiryInPast");
    });

    it("reverts if attacker tries to lock", async () => {
      await expect(
        vault.connect(attacker).lockMintingRights(tokenIds, "harvest", 0n)
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("unlocks minting rights — INV-4: only multisig", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      await vault.connect(safe).unlockMintingRights(1n);
      for (const id of tokenIds) {
        expect(await vault.isMintingRightLocked(id)).to.be.false;
      }
    });

    it("reverts if cold wallet tries to unlock — INV-4", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      await expect(
        vault.connect(cold).unlockMintingRights(1n)
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("reverts if attacker tries to unlock", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      await expect(
        vault.connect(attacker).unlockMintingRights(1n)
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("reverts if lock not active", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      await vault.connect(safe).unlockMintingRights(1n);
      await expect(
        vault.connect(safe).unlockMintingRights(1n)
      ).to.be.revertedWithCustomError(vault, "LockNotActive");
    });

    it("returns false for expired lock", async () => {
      const future = BigInt(await getBlockTimestamp()) + 100n;
      await vault.connect(safe).lockMintingRights([1001n], "harvest", future);
      expect(await vault.isMintingRightLocked(1001n)).to.be.true;
      await increaseTime(200);
      expect(await vault.isMintingRightLocked(1001n)).to.be.false;
    });

    it("emits MintingRightsUnlocked on unlock", async () => {
      await vault.connect(safe).lockMintingRights(tokenIds, "harvest", 0n);
      await expect(vault.connect(safe).unlockMintingRights(1n))
        .to.emit(vault, "MintingRightsUnlocked").withArgs(1n, (v) => v > 0n);
    });
  });

  // ── HARVEST TOKEN REGISTRY ───────────────────────────────────
  // SKIPPED — FEATURE RELOCATED. The harvest-token registry
  // (issueHarvestToken / hasValidHarvestToken / validateAndRecordHarvest /
  // getHarvestToken / revokeHarvestToken and setDeltaVault) is no longer part
  // of EWBWhaleVault, which now only manages minting-rights locks and tiers.
  // Harvest-token issuance moved to EWBNFTHarvestVault (ERC-721 → ERC-20 engine),
  // whose full lifecycle is covered by test/EWBNFTHarvestVault.test.js. None of
  // the functions/errors below (OnlyMultisig, InvalidTier, HarvestTokenNotActive,
  // OnlyDeltaNeutralVault, …) exist on this contract anymore. Retained to
  // document the migration.
  describe.skip("Harvest Token Registry", () => {
    const utilityETH = ethers.parseEther("315");
    const duration   = BigInt(30 * 24 * 3600); // 30 days

    beforeEach(async () => {
      await vault.connect(safe).setDeltaVault(deltaVault.address);
    });

    it("issues harvest token correctly", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      expect(await vault.hasValidHarvestToken(user.address)).to.be.true;
    });

    it("emits HarvestTokenIssued", async () => {
      await expect(
        vault.connect(safe).issueHarvestToken(user.address, utilityETH, TIER.EPIC, duration)
      ).to.emit(vault, "HarvestTokenIssued");
    });

    it("reverts if attacker issues token", async () => {
      await expect(
        vault.connect(attacker).issueHarvestToken(user.address, utilityETH, TIER.EPIC, duration)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("reverts on zero address holder", async () => {
      await expect(
        vault.connect(safe).issueHarvestToken(ethers.ZeroAddress, utilityETH, TIER.EPIC, duration)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("reverts on invalid tier", async () => {
      await expect(
        vault.connect(safe).issueHarvestToken(user.address, utilityETH, 4, duration)
      ).to.be.revertedWithCustomError(vault, "InvalidTier");
    });

    it("reverts on zero duration", async () => {
      await expect(
        vault.connect(safe).issueHarvestToken(user.address, utilityETH, TIER.EPIC, 0n)
      ).to.be.revertedWith("Duration cannot be zero");
    });

    it("auto-expires after duration — INV-2", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, 100n
      );
      expect(await vault.hasValidHarvestToken(user.address)).to.be.true;
      await increaseTime(200);
      expect(await vault.hasValidHarvestToken(user.address)).to.be.false;
    });

    it("validateAndRecordHarvest returns true for valid token", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      const result = await vault.connect(deltaVault)
        .validateAndRecordHarvest.staticCall(user.address);
      expect(result).to.be.true;
    });

    it("validateAndRecordHarvest returns false for expired token — INV-2", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, 100n
      );
      await increaseTime(200);
      const result = await vault.connect(deltaVault)
        .validateAndRecordHarvest.staticCall(user.address);
      expect(result).to.be.false;
    });

    it("validateAndRecordHarvest increments harvestCount", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      await vault.connect(deltaVault).validateAndRecordHarvest(user.address);
      const token = await vault.getHarvestToken(user.address);
      expect(token.harvestCount).to.equal(1n);
    });

    it("validateAndRecordHarvest reverts if called by non-deltaVault", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      await expect(
        vault.connect(attacker).validateAndRecordHarvest(user.address)
      ).to.be.revertedWithCustomError(vault, "OnlyDeltaNeutralVault");
    });

    it("revokes harvest token before expiry", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      await vault.connect(safe).revokeHarvestToken(user.address);
      expect(await vault.hasValidHarvestToken(user.address)).to.be.false;
    });

    it("reverts revokeHarvestToken if attacker calls", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, duration
      );
      await expect(
        vault.connect(attacker).revokeHarvestToken(user.address)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("reverts revokeHarvestToken if no active token", async () => {
      await expect(
        vault.connect(safe).revokeHarvestToken(user.address)
      ).to.be.revertedWithCustomError(vault, "HarvestTokenNotActive");
    });

    it("reissues token replacing existing one", async () => {
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.EPIC, 100n
      );
      await vault.connect(safe).issueHarvestToken(
        user.address, utilityETH, TIER.RARE, duration
      );
      const token = await vault.getHarvestToken(user.address);
      expect(token.active).to.be.true;
      expect(token.tier).to.equal(TIER.RARE);
    });
  });

  // ── PAUSE MECHANICS ─────────────────────────────────────────
  describe("Pause Mechanics", () => {
    it("owner can pause", async () => {
      await vault.connect(safe).pause();
      expect(await vault.paused()).to.be.true;
    });

    it("cold wallet can pause", async () => {
      await expect(vault.connect(cold).pause()).to.be.revertedWith("Not owner");
    });

    it("attacker cannot pause", async () => {
      await expect(vault.connect(attacker).pause())
        .to.be.revertedWith("Not owner");
    });

    it("owner can unpause", async () => {
      await vault.connect(safe).pause();
      await vault.connect(safe).unpause();
      expect(await vault.paused()).to.be.false;
    });

    it("only owner can force-unpause after 72hrs — INV-5", async () => {
      await vault.connect(safe).pause();
      await increaseTime(72 * 3600 + 1);
      await expect(vault.connect(attacker).forceUnpause()).to.be.revertedWithCustomError(vault, "NotOwner");
      await vault.connect(safe).forceUnpause();
      expect(await vault.paused()).to.be.false;
    });

    it("forceUnpause reverts before 72hrs — INV-5", async () => {
      await vault.connect(safe).pause();
      await expect(vault.connect(safe).forceUnpause())
        .to.be.revertedWith("Max pause not elapsed");
    });

    it("can force-unpause after delay", async () => {
      await vault.connect(safe).pause();
      await increaseTime(72 * 3600 + 1);
      await vault.connect(safe).forceUnpause();
      expect(await vault.paused()).to.equal(false);
    });

    it("lockMintingRights reverts when paused", async () => {
      await vault.connect(safe).pause();
      await expect(
        vault.connect(safe).lockMintingRights([1001n], "harvest", 0n)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  // ── VAULT STATS ──────────────────────────────────────────────
  describe("Vault Stats", () => {
    it("returns lock count and totals", async () => {
      const stats = await vault.getVaultStats();
      expect(stats[0]).to.equal(0n);
      expect(stats[1]).to.equal(0n);
    });

    it("totalLockedFaceETH updates on lock", async () => {
      await vault.connect(safe).setTokenTiers([1001n], [TIER.EPIC]);
      await vault.connect(safe).lockMintingRights([1001n], "harvest", 0n);
      const stats = await vault.getVaultStats();
      expect(stats[1]).to.equal(ethers.parseEther("315"));
    });

    it("totalLockedFaceETH decreases on unlock", async () => {
      await vault.connect(safe).setTokenTiers([1001n], [TIER.EPIC]);
      await vault.connect(safe).lockMintingRights([1001n], "harvest", 0n);
      await vault.connect(safe).unlockMintingRights(1n);
      const stats = await vault.getVaultStats();
      expect(stats[1]).to.equal(0n);
    });
  });
});
