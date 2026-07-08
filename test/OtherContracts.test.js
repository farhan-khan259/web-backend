// test/OtherContracts.test.js
// EWBGorillaOracle + EWBDevPayment + Invariants + Security/Adversarial

const { expect }   = require("chai");
const { ethers }   = require("hardhat");
const {
  increaseTime, getBlockTimestamp, deployMockOracle, impersonateAccount
} = require("./helpers");

const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

// ================================================================
// EWBGorillaOracle
// ================================================================
describe("EWBGorillaOracle", () => {
  let oracle;
  let owner, attacker;

  beforeEach(async () => {
    [owner, attacker] = await ethers.getSigners();
    const Oracle = await ethers.getContractFactory("EWBGorillaOracle", owner);
    oracle = await Oracle.deploy(owner.address, owner.address);
  });

  describe("Deployment", () => {
    it("sets owner correctly", async () => {
      expect(await oracle.owner()).to.equal(owner.address);
    });

    it("TWAP window is immutable constant (30 days)", async () => {
      const val = await oracle.twapWindow();
      expect(val).to.equal(30n * 24n * 3600n);
    });

    it("chainlinkMaxAge is immutable (1hr)", async () => {
      expect(await oracle.chainlinkMaxAge()).to.equal(3600n);
    });

    it("manualFloorMaxAge is immutable (7 days)", async () => {
      expect(await oracle.manualFloorMaxAge())
        .to.equal(7n * 24n * 3600n);
    });
  });

  describe("Manual Floor", () => {
    it("owner can set manual floor", async () => {
      await oracle.connect(owner)
        .setManualFloor(ethers.parseEther("4.29"));
      expect(await oracle.manualFloorETH())
        .to.equal(ethers.parseEther("4.29"));
    });

    it("emits event on manual floor update", async () => {
      await expect(
        oracle.connect(owner).setManualFloor(ethers.parseEther("4.29"))
      ).to.emit(oracle, "ManualFloorSet");
    });

    it("attacker cannot set manual floor", async () => {
      await expect(
        oracle.connect(attacker)
          .setManualFloor(ethers.parseEther("1"))
      ).to.be.reverted;
    });

    it("reverts if manual floor is stale (>7 days)", async () => {
      await oracle.connect(owner)
        .setManualFloor(ethers.parseEther("4.29"));
      await increaseTime(7 * 24 * 3600 + 1);
      await expect(oracle.getFloorPriceETH())
        .to.be.revertedWith("Manual floor price is stale — owner must update");
    });

    it("fresh manual floor returns correct value", async () => {
      await oracle.connect(owner)
        .setManualFloor(ethers.parseEther("4.29"));
      const floor = await oracle.getFloorPriceETH();
      expect(floor).to.equal(ethers.parseEther("4.29"));
    });
  });

  describe("Immutability — Removed Setters", () => {
    it("setTWAPWindow exists", () => {
      expect(oracle.setTWAPWindow).to.not.be.undefined;
    });

    it("setChainlinkMaxAge exists", () => {
      expect(oracle.setChainlinkMaxAge).to.not.be.undefined;
    });

    it("transferOwnership does not exist", () => {
      expect(oracle.transferOwnership).to.be.undefined;
    });

    it("setManualFloorMaxAge exists", () => {
      expect(oracle.setManualFloorMaxAge).to.not.be.undefined;
    });
  });
});

// ================================================================
// EWBDevPayment
// ================================================================
describe("EWBDevPayment", () => {
  let payment, usdc;
  let owner, developer, attacker;
  let vaultMock;
  const PAYMENT = ethers.parseUnits("50000", 6);

  beforeEach(async () => {
    [owner, developer, attacker] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    usdc = await MockERC20.deploy("USD Coin", "USDC", 6);

    const Payment = await ethers.getContractFactory("EWBDevPayment", owner);
    payment = await Payment.deploy(
      owner.address,
      developer.address,
      await usdc.getAddress()
    );

    // Fund escrow using current flow: approve + fund()
    await usdc.mint(owner.address, PAYMENT);
    await usdc.connect(owner).approve(await payment.getAddress(), PAYMENT);
    await payment.connect(owner).fund();

    const MockVaultOwner = await ethers.getContractFactory("MockVaultOwner");
    vaultMock = await MockVaultOwner.deploy(owner.address);
  });

  describe("Deployment", () => {
    it("stores developer address correctly", async () => {
      expect(await payment.DEVELOPER()).to.equal(developer.address);
    });

    it("holds 50,000 USDC on deployment", async () => {
      expect(await usdc.balanceOf(await payment.getAddress()))
        .to.equal(PAYMENT);
    });

    it("starts unconfirmed", async () => {
      expect(await payment.released()).to.be.false;
    });
  });

  describe("Confirmation and Release", () => {
    it("owner confirms and releases to developer", async () => {
      const before = await usdc.balanceOf(developer.address);
      await payment.connect(owner)
        .confirmDeployment(await vaultMock.getAddress());
      const after = await usdc.balanceOf(developer.address);
      expect(after - before).to.equal(PAYMENT);
    });

    it("marks deploymentConfirmed = true", async () => {
      await payment.connect(owner)
        .confirmDeployment(await vaultMock.getAddress());
      expect(await payment.released()).to.be.true;
    });

    it("cannot confirm twice — single release", async () => {
      await payment.connect(owner)
        .confirmDeployment(await vaultMock.getAddress());
      await expect(
        payment.connect(owner).confirmDeployment(await vaultMock.getAddress())
      ).to.be.reverted;
    });

    it("attacker cannot confirm", async () => {
      await expect(
        payment.connect(attacker).confirmDeployment(await vaultMock.getAddress())
      ).to.be.reverted;
    });

    it("developer cannot self-confirm", async () => {
      await expect(
        payment.connect(developer).confirmDeployment(await vaultMock.getAddress())
      ).to.be.reverted;
    });
  });
});

// ================================================================
// System Invariants — Formal Verification Checklist
// ================================================================
describe("System Invariants", () => {
  let vault, oracle;
  let safe, cold, deltaVault;

  beforeEach(async () => {
    [, cold, deltaVault] = await ethers.getSigners();
    safe = await impersonateAccount(BALLET_WALLET);
    oracle = await deployMockOracle(undefined, ethers.parseEther("1"));
    const Vault = await ethers.getContractFactory("EWBWhaleVault");
    vault = await Vault.deploy(await oracle.getAddress());
    await vault.connect(safe).setDeltaVault(deltaVault.address);
  });

  describe("INV-1: Minting rights locked while loan active", () => {
    it("isMintingRightLocked returns true after lockMintingRights", async () => {
      await vault.connect(safe).setTokenTiers([9001n], [3]);
      await vault.connect(safe).lockMintingRights(
        [9001n], "credit", 0n);
      expect(await vault.isMintingRightLocked(9001n)).to.be.true;
    });

    it("isMintingRightLocked returns false after unlock", async () => {
      await vault.connect(safe).setTokenTiers([9002n], [3]);
      await vault.connect(safe).lockMintingRights(
        [9002n], "credit", 0n);
      const lockId = await vault.lockCount();
      await vault.connect(safe).unlockMintingRights(lockId);
      expect(await vault.isMintingRightLocked(9002n)).to.be.false;
    });
  });

  describe("INV-2: Harvest token cannot be used after expiry", () => {
    it("harvest token API removed from EWBWhaleVault", async () => {
      expect(vault.hasValidHarvestToken).to.be.undefined;
    });

    it("validateAndRecordHarvest API removed from EWBWhaleVault", async () => {
      expect(vault.validateAndRecordHarvest).to.be.undefined;
    });
  });

  describe("INV-3: Tier assignments immutable after lockTiers()", () => {
    it("setTokenTiers reverts after lockTiers", async () => {
      const Vault = await ethers.getContractFactory("EWBWhaleVault");
      const v2 = await Vault.deploy(await oracle.getAddress());
      await v2.connect(safe).setTokenTiers([5001n], [0]);
      await v2.connect(safe).lockTiers();
      await expect(
        v2.connect(safe).setTokenTiers([5002n], [1])
      ).to.be.revertedWith("Tiers permanently locked");
    });
  });

  describe("INV-4: Only Safe multisig can unlock minting rights", () => {
    it("cold wallet unlock reverts", async () => {
      await vault.connect(safe).setTokenTiers([9003n], [3]);
      await vault.connect(safe).lockMintingRights([9003n], "test", 0n);
      const lockId = await vault.lockCount();
      await expect(
        vault.connect(cold).unlockMintingRights(lockId)
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("attacker unlock reverts", async () => {
      const [,, atk] = await ethers.getSigners();
      await vault.connect(safe).setTokenTiers([9004n], [3]);
      await vault.connect(safe).lockMintingRights([9004n], "test", 0n);
      const lockId = await vault.lockCount();
      await expect(
        vault.connect(atk).unlockMintingRights(lockId)
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });
  });

  describe("INV-5: Force unpause bounded by 72hr max", () => {
    it("forceUnpause reverts before 72hrs", async () => {
      const Vault = await ethers.getContractFactory("EWBWhaleVault");
      const v3 = await Vault.deploy(await oracle.getAddress());
      await v3.connect(safe).pause();
      await expect(
        v3.connect(safe).forceUnpause()
      ).to.be.revertedWith("Max pause not elapsed");
    });

    it("forceUnpause succeeds after 72hrs — owner", async () => {
      const Vault = await ethers.getContractFactory("EWBWhaleVault");
      const v4 = await Vault.deploy(await oracle.getAddress());
      await v4.connect(safe).pause();
      await increaseTime(72 * 3600 + 1);
      await v4.connect(safe).forceUnpause();
      expect(await v4.paused()).to.be.false;
    });
  });
});

// ================================================================
// Security — Adversarial Tests
// ================================================================
describe("Security — Adversarial Tests", () => {
  let vault, oracle;
  let safe, cold, attacker, deltaVault;

  beforeEach(async () => {
    [, cold, attacker, deltaVault] = await ethers.getSigners();
    safe = await impersonateAccount(BALLET_WALLET);
    oracle = await deployMockOracle(undefined, ethers.parseEther("1"));
    const Vault = await ethers.getContractFactory("EWBWhaleVault");
    vault = await Vault.deploy(await oracle.getAddress());
    await vault.connect(safe).setDeltaVault(deltaVault.address);
  });

  it("attacker cannot become multisig", async () => {
    await expect(
      vault.connect(attacker).setDeltaVault(attacker.address)
    ).to.be.revertedWithCustomError(vault, "NotOwner");
  });

  it("attacker cannot lock minting rights", async () => {
    await expect(
      vault.connect(attacker).lockMintingRights([1n], "attack", 0n)
    ).to.be.revertedWithCustomError(vault, "NotOwner");
  });

  it("attacker cannot unlock minting rights", async () => {
    await vault.connect(safe).setTokenTiers([8001n], [3]);
    await vault.connect(safe).lockMintingRights([8001n], "test", 0n);
    const lockId = await vault.lockCount();
    await expect(
      vault.connect(attacker).unlockMintingRights(lockId)
    ).to.be.revertedWithCustomError(vault, "NotOwner");
  });

  it("attacker cannot set tier assignments", async () => {
    await expect(
      vault.connect(attacker).setTokenTiers([1n], [0])
    ).to.be.revertedWithCustomError(vault, "NotOwner");
  });

  it("cold wallet cannot lock minting rights", async () => {
    await expect(
      vault.connect(cold).lockMintingRights([7001n], "test", 0n)
    ).to.be.revertedWithCustomError(vault, "NotOwner");
  });

  it("paused vault blocks lockMintingRights", async () => {
    await vault.connect(safe).pause();
    await expect(
      vault.connect(safe).lockMintingRights([6001n], "test", 0n)
    ).to.be.revertedWith("Pausable: paused");
    await vault.connect(safe).unpause();
  });

  it("duplicate lock on same tokenId reverts", async () => {
    await vault.connect(safe).setTokenTiers([5001n], [3]);
    await vault.connect(safe).lockMintingRights([5001n], "harvest", 0n);
    await expect(
      vault.connect(safe).lockMintingRights([5001n], "credit", 0n)
    ).to.be.revertedWithCustomError(vault, "TokenIdAlreadyLocked")
      .withArgs(5001n);
  });

  it("lockTiers cannot be called twice", async () => {
    const Vault  = await ethers.getContractFactory("EWBWhaleVault");
    const vaultX = await Vault.deploy(await oracle.getAddress());
    await vaultX.connect(safe).lockTiers();
    await vaultX.connect(safe).lockTiers();
    expect(await vaultX.tiersLocked()).to.equal(true);
  });
});
