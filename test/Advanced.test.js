// test/Advanced.test.js
// OZ pre-audit gap-fill tests
// Covers: cross-contract invariants, boundary timestamps, reentrancy,
//         oracle manipulation, NFT edge cases, gas/DoS, event integrity

const { expect }  = require("chai");
const { ethers }  = require("hardhat");
const {
  increaseTime, getBlockTimestamp, deployMockOracle,
  signKYCAttestation, signHedgeAttestation,
  KYC_MAX_AGE, MAX_PAUSE_DURATION,
  impersonateAccount, etchDeltaNeutralMocks,
} = require("./helpers");

// EWBWhaleVault hard-codes its owner to the Ballet wallet, so owner-only
// calls must come from an impersonated signer for that address.
const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";

// ================================================================
// CROSS-CONTRACT INVARIANTS
// ================================================================
// SKIPPED — OBSOLETE API. deploySystem() drives the removed EWBMintingRightsVault
// lending pool (depositSPV / setHardScanAttestor) and EWBWhaleVault.issueHarvestToken
// (harvest tokens moved to EWBNFTHarvestVault). Cross-contract state independence is
// covered by the Foundry invariant suite. Retained for provenance.
describe.skip("Cross-Contract Invariants", () => {
  let whaleVault, mintingVault, oracle;
  let safe, cold, hardScan, borrower, deltaVault;

  async function deploySystem() {
    [safe, cold, hardScan, borrower, deltaVault] =
      await ethers.getSigners();

    oracle = await deployMockOracle(safe);

    const MockWhaleVault = await ethers.getContractFactory("MockWhaleVault");
    const mockWV = await MockWhaleVault.deploy();

    const WV = await ethers.getContractFactory("EWBWhaleVault");
    whaleVault = await WV.deploy(await oracle.getAddress());
    
    // Impersonate BALLET_WALLET (owner) to call owner-only functions
    const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";
    await ethers.provider.send("hardhat_impersonateAccount", [BALLET_WALLET]);
    const walletSigner = await ethers.getSigner(BALLET_WALLET);
    await ethers.provider.send("hardhat_setBalance", [BALLET_WALLET, "0x8AC7230489E80000"]);
    await whaleVault.connect(walletSigner).setDeltaVault(deltaVault.address);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("USD Coin","USDC",6);

    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    mintingVault = await MV.deploy(await mockWV.getAddress());

    // Set up pool
    const seed = ethers.parseUnits("500000",6);
    await usdc.mint(safe.address, seed);
    await usdc.connect(safe).approve(
      await mintingVault.getAddress(), ethers.MaxUint256);
    await mintingVault.connect(safe).depositSPV(seed);

    // Register KYC attestor
    await mintingVault.connect(safe)
      .setHardScanAttestor(hardScan.address);

    // Lock minting rights in mock whale vault
    await mockWV.setLocked([1001n,1002n], true);

    return { usdc, mockWV };
  }

  it("loan active → minting rights stay locked even after vault pause/unpause", async () => {
    await deploySystem();

    // Lock in real whale vault
    await whaleVault.connect(safe).lockMintingRights(
      [5001n], "credit", 0n);

    expect(await whaleVault.isMintingRightLocked(5001n)).to.be.true;

    // Pause and unpause
    await whaleVault.connect(safe).pause();
    await whaleVault.connect(safe).unpause();

    // Still locked
    expect(await whaleVault.isMintingRightLocked(5001n)).to.be.true;
  });

  it("loan active → oracle price change does not unlock minting rights", async () => {
    await deploySystem();
    await whaleVault.connect(safe).lockMintingRights(
      [5002n], "credit", 0n);

    // Crash oracle floor
    const MockOracle = await ethers.getContractFactory("MockOracle");
    const crashedOracle = await MockOracle.deploy(
      ethers.parseEther("0.01"),
      ethers.parseUnits("100", 8)
    );
    // Rights remain locked regardless of oracle price
    expect(await whaleVault.isMintingRightLocked(5002n)).to.be.true;
  });

  it("harvest token expiry at exact same block as issue + duration", async () => {
    await deploySystem();
    const duration = 3600n;
    await whaleVault.connect(safe).issueHarvestToken(
      borrower.address, ethers.parseEther("315"), 0, duration);

    // At exactly expiresAt — should be invalid (>=)
    await increaseTime(Number(duration));
    expect(await whaleVault.hasValidHarvestToken(borrower.address))
      .to.be.false;
  });

  it("tier lock does not unlock minting rights", async () => {
    await deploySystem();
    await whaleVault.connect(safe).setTokenTiers([6001n],[0]);
    await whaleVault.connect(safe).lockMintingRights(
      [6001n], "harvest", 0n);
    await whaleVault.connect(safe).lockTiers();

    // Minting rights still locked after tier lock
    expect(await whaleVault.isMintingRightLocked(6001n)).to.be.true;
  });

  it("emergency exit triggered — minting rights remain locked", async () => {
    await deploySystem();
    await whaleVault.connect(safe).lockMintingRights(
      [7001n], "credit", 0n);

    // Trigger emergency exit on delta vault (separate contract)
    // Whale vault lock is independent — still locked
    expect(await whaleVault.isMintingRightLocked(7001n)).to.be.true;
  });
});

// ================================================================
// BOUNDARY TIMESTAMP TESTS (exact equality)
// ================================================================
// SKIPPED — OBSOLETE API. Uses the old EWBWhaleVault 3-arg constructor and the
// removed harvest-token functions (issueHarvestToken / hasValidHarvestToken /
// setDeltaVault) plus a MaxPauseNotReached custom error the contract no longer
// declares. Harvest-token boundary behaviour is covered by
// test/EWBNFTHarvestVault.test.js; minting-lock expiry boundaries by the
// EWBWhaleVault suite. Retained for provenance.
describe.skip("Boundary Timestamp Tests", () => {
  let vault, oracle;
  let safe, cold, deltaVault, user;

  beforeEach(async () => {
    [safe, cold, deltaVault, user] = await ethers.getSigners();
    oracle = await deployMockOracle(safe);
    const Vault = await ethers.getContractFactory("EWBWhaleVault");
    vault = await Vault.deploy(
      safe.address, cold.address, await oracle.getAddress());
    await vault.connect(safe).setDeltaVault(deltaVault.address);
  });

  // Harvest token — exact boundary
  it("harvest token: invalid at exactly expiresAt (>=)", async () => {
    const duration = 1000n;
    await vault.connect(safe).issueHarvestToken(
      user.address, ethers.parseEther("1"), 3, duration);
    await increaseTime(Number(duration)); // exactly at boundary
    expect(await vault.hasValidHarvestToken(user.address)).to.be.false;
  });

  it("harvest token: valid one second before expiresAt", async () => {
    const duration = 1000n;
    await vault.connect(safe).issueHarvestToken(
      user.address, ethers.parseEther("1"), 3, duration);
    await increaseTime(Number(duration) - 1);
    expect(await vault.hasValidHarvestToken(user.address)).to.be.true;
  });

  // Force unpause — exact boundary
  it("forceUnpause: reverts at exactly 72hr - 1 second", async () => {
    await vault.connect(safe).pause();
    await increaseTime(MAX_PAUSE_DURATION - 1);
    await expect(vault.connect(user).forceUnpause())
      .to.be.revertedWithCustomError(vault, "MaxPauseNotReached");
  });

  it("forceUnpause: succeeds at exactly 72hr", async () => {
    await vault.connect(safe).pause();
    await increaseTime(MAX_PAUSE_DURATION);
    await expect(vault.connect(user).forceUnpause())
      .to.not.be.reverted;
  });

  // Minting lock expiry — exact boundary
  it("minting lock: locked one second before expiry", async () => {
    const expiry = BigInt(await getBlockTimestamp()) + 1000n;
    await vault.connect(safe).lockMintingRights(
      [8001n], "test", expiry);
    await increaseTime(998);
    expect(await vault.isMintingRightLocked(8001n)).to.be.true;
  });

  it("minting lock: expired at exactly expiresAt", async () => {
    const ts = BigInt(await getBlockTimestamp());
    const expiry = ts + 1000n;
    await vault.connect(safe).lockMintingRights(
      [8002n], "test", expiry);
    await increaseTime(1001);
    expect(await vault.isMintingRightLocked(8002n)).to.be.false;
  });
});

// SKIPPED — OBSOLETE API. The HardScan KYC layer (submitKYCAttestation /
// isKYCFresh) and the 4-arg EWBMintingRightsVault constructor were removed in
// the redesign to a minting-rights → Aave USDC borrow facility. Retained for
// provenance. See test/EWBMintingRightsVault.test.js header for details.
describe.skip("KYC Boundary Timestamps", () => {
  let vault, hardScan, borrower;

  async function signAndSubmit(vaultC, attestor, addr, offset) {
    const ts    = BigInt(await getBlockTimestamp()) + offset;
    const nonce = ethers.randomBytes(32);
    const sig   = await signKYCAttestation(attestor, addr, "KYC-BND", ts, nonce);
    await vaultC.connect(attestor).submitKYCAttestation(
      addr, "KYC-BND", ts, nonce, sig);
  }

  beforeEach(async () => {
    const signers = await ethers.getSigners();
    [,, hardScan, borrower] = signers;
    const safe = signers[0]; const cold = signers[1];

    const oracle = await deployMockOracle(safe);
    const MockWV = await ethers.getContractFactory("MockWhaleVault");
    const mockWV = await MockWV.deploy();

    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    vault = await MV.deploy(
      safe.address, cold.address,
      await mockWV.getAddress(),
      await oracle.getAddress()
    );
    await vault.connect(safe).setHardScanAttestor(hardScan.address);
  });

  it("KYC: fresh at exactly 24hr - 1 second", async () => {
    await signAndSubmit(vault, hardScan, borrower.address, 0n);
    await increaseTime(KYC_MAX_AGE - 1);
    const [fresh] = await vault.isKYCFresh(borrower.address);
    expect(fresh).to.be.true;
  });

  it("KYC: stale at exactly 24hr", async () => {
    await signAndSubmit(vault, hardScan, borrower.address, 0n);
    await increaseTime(KYC_MAX_AGE);
    const [fresh] = await vault.isKYCFresh(borrower.address);
    expect(fresh).to.be.false;
  });
});

describe("Hedge Attestation Boundary Timestamps", () => {
  let vault, bot, safe, cold;

  beforeEach(async () => {
    [safe, cold, bot] = await ethers.getSigners();
    // submitHedgeAttestation cross-checks the live Aave HF — etch mocks.
    await etchDeltaNeutralMocks();
    const V = await ethers.getContractFactory("EWBDeltaNeutralVault");
    vault = await V.deploy(safe.address, cold.address, safe.address);
    await vault.connect(safe).setHedgeAttestor(bot.address);
  });

  async function submitNow() {
    const now   = BigInt(await getBlockTimestamp());
    const nonce = ethers.hexlify(ethers.randomBytes(32));
    const sig   = await signHedgeAttestation(
      bot, ethers.parseEther("1000"), 100n, 0n, 800n, now, "acct", nonce);
    await vault.connect(bot).submitHedgeAttestation(
      ethers.parseEther("1000"), 100n, 0n, 800n, "acct", now, nonce, sig);
  }

  // ATTESTATION_MAX_AGE was tightened to 15 minutes (900s) by FIX R3.
  it("attestation: fresh just under the 15min window (FIX R3)", async () => {
    await submitNow();
    await increaseTime(899);
    const [fresh] = await vault.isHedgeAttestationFresh();
    expect(fresh).to.be.true;
  });

  it("attestation: stale just past the 15min window (FIX R3)", async () => {
    await submitNow();
    await increaseTime(901);
    const [fresh] = await vault.isHedgeAttestationFresh();
    expect(fresh).to.be.false;
  });
});

// ================================================================
// REENTRANCY ADVERSARIAL TESTS
// ================================================================
// SKIPPED — OBSOLETE API. Targets the removed EWBMintingRightsVault lending pool
// (4-arg constructor, withdrawLender, getPoolStats). Reentrancy protection on the
// live SafeERC20 transfer paths is covered by the Foundry invariant suite.
// Retained for provenance.
describe.skip("Reentrancy Adversarial Tests", () => {
  let mintingVault, reentrantToken;
  let safe, cold, hardScan, attacker;

  beforeEach(async () => {
    [safe, cold, hardScan, attacker] = await ethers.getSigners();

    const oracle = await deployMockOracle(safe);
    const MockWV = await ethers.getContractFactory("MockWhaleVault");
    const mockWV = await MockWV.deploy();
    await mockWV.setLocked([1001n], true);

    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    mintingVault = await MV.deploy(
      safe.address, cold.address,
      await mockWV.getAddress(),
      await oracle.getAddress()
    );

    // Deploy reentrant token
    const RT = await ethers.getContractFactory("ReentrantERC20");
    reentrantToken = await RT.deploy();

    // Seed the vault with reentrant token
    await reentrantToken.mint(attacker.address,
      ethers.parseUnits("100000", 6));
    await reentrantToken.connect(attacker).approve(
      await mintingVault.getAddress(), ethers.MaxUint256);
  });

  it("withdrawLender: reentrancy via malicious ERC20 is blocked", async () => {
    // The pool uses SafeERC20 + nonReentrant
    // Encode a reentrant withdrawLender call
    const reentrantCalldata = mintingVault.interface.encodeFunctionData(
      "withdrawLender", [ethers.parseUnits("1000", 6)]);

    await reentrantToken.setReentrantTarget(
      await mintingVault.getAddress(), reentrantCalldata);

    // Direct reentrancy attack should not drain extra funds
    // nonReentrant guard catches the inner call
    // We verify the vault balance is consistent after the attack attempt
    // (the attack itself will likely revert or be caught by guard)
    const statsBefore = await mintingVault.getPoolStats();
    expect(statsBefore.balance).to.equal(0n); // no funds deposited yet
  });

  it("nonReentrant modifier is present on withdrawLender", async () => {
    // Test that consecutive calls are safe — no state corruption
    await reentrantToken.mint(safe.address, ethers.parseUnits("1000000",6));
    // This verifies the function exists with proper access control
    await expect(mintingVault.connect(attacker).withdrawLender(1n))
      .to.be.reverted; // No deposit → reverts safely
  });
});

// ================================================================
// ORACLE MANIPULATION SCENARIOS
// ================================================================
describe("Oracle Manipulation Scenarios", () => {
  let vault, oracle;
  let safe, cold;

  beforeEach(async () => {
    const signers = await ethers.getSigners();
    cold = signers[1];
    // EWBWhaleVault owner is the hard-coded Ballet wallet — impersonate it.
    safe = await impersonateAccount(BALLET_WALLET);
    // floorETH = 0 disables the MEV snapshot deviation check on lock.
    oracle = await deployMockOracle(safe, 0n);
    const V = await ethers.getContractFactory("EWBWhaleVault", safe);
    vault = await V.deploy(await oracle.getAddress());
    await vault.connect(safe).setTokenTiers([1001n],[0]); // EPIC
  });

  it("floor price crash: minting lock face value recorded at origination price", async () => {
    // Lock at current price
    await vault.connect(safe).lockMintingRights([1001n], "credit", 0n);
    const lockBefore = await vault.getLock(1n);
    const faceAtOrigin = lockBefore.faceValueETH;

    // Crash the oracle
    await oracle.setFloorPrice(ethers.parseEther("0.01"));
    await oracle.setETHUSD(ethers.parseUnits("100", 8));

    // Face value recorded at origination is unchanged
    const lockAfter = await vault.getLock(1n);
    expect(lockAfter.faceValueETH).to.equal(faceAtOrigin);
  });

  it("floor spike: ERC-7621 cap prevents borrowing above face value LTV", async () => {
    // Spike oracle price
    await oracle.setETHUSD(ethers.parseUnits("100000", 8)); // $100k ETH

    // Even with high oracle price, face value is bounded by tier floor ETH
    // not oracle-inflated values — ERC-7621 cap holds
    await vault.connect(safe).lockMintingRights([1001n], "credit", 0n);
    const lock = await vault.getLock(1n);

    // Face value ETH is tier floor (315 ETH) regardless of oracle
    expect(lock.faceValueETH).to.equal(ethers.parseEther("315"));
  });

  it("manual floor staleness: getFloorPriceETH reverts after 7 days", async () => {
    // Set up oracle with manual floor — constructor is (ewbPool, owner)
    const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
    const realOracle = await Oracle.deploy(ethers.ZeroAddress, safe.address);
    await realOracle.connect(safe)
      .setManualFloor(ethers.parseEther("4.29"));

    await increaseTime(7 * 24 * 3600 + 1);
    await expect(realOracle.getFloorPriceETH())
      .to.be.revertedWith("Manual floor price is stale — owner must update");
  });

  it("extreme Curve peg (0.7): MockCurvePool returns manipulated ratio", async () => {
    const MockCurve = await ethers.getContractFactory("MockCurvePool");
    const curve = await MockCurve.deploy();

    // Set depeg ratio to 0.70
    await curve.setPegRatio(ethers.parseEther("0.70"));
    const output = await curve.get_dy(1, 0, ethers.parseEther("1"));

    // 0.70 < 0.90 threshold — would trigger emergency exit in real system
    expect(output).to.be.lt(ethers.parseEther("0.90"));
  });
});

// ================================================================
// NFT EDGE CASES
// ================================================================
describe("NFT / Token Ownership Edge Cases", () => {
  let vault, oracle;
  let safe, cold, user;

  beforeEach(async () => {
    const signers = await ethers.getSigners();
    cold = signers[1]; user = signers[2];
    safe = await impersonateAccount(BALLET_WALLET);
    oracle = await deployMockOracle(safe, 0n); // floor 0 → MEV check skipped
    const V = await ethers.getContractFactory("EWBWhaleVault", safe);
    vault = await V.deploy(await oracle.getAddress());
    // Every tokenId exercised below must have a tier assigned before it can
    // be locked (lockMintingRights reverts TierNotAssigned otherwise).
    const ids = [9001n, 9002n, 9003n, 9004n, 9005n, 9006n];
    for (let i = 0; i < 50; i++) ids.push(BigInt(10000 + i));
    await vault.connect(safe).setTokenTiers(ids, ids.map(() => 3)); // STANDARD
  });

  it("can lock tokenId that was previously unlocked (no ghost lock)", async () => {
    await vault.connect(safe).lockMintingRights([9001n], "test", 0n);
    const lockId = await vault.lockCount();
    await vault.connect(safe).unlockMintingRights(lockId);

    // Should be lockable again
    await expect(
      vault.connect(safe).lockMintingRights([9001n], "test", 0n)
    ).to.not.be.reverted;
    expect(await vault.isMintingRightLocked(9001n)).to.be.true;
  });

  it("tokenIdLocked mapping clears correctly on unlock", async () => {
    await vault.connect(safe).lockMintingRights(
      [9002n, 9003n, 9004n], "test", 0n);
    const lockId = await vault.lockCount();

    for (const id of [9002n, 9003n, 9004n]) {
      expect(await vault.isMintingRightLocked(id)).to.be.true;
    }

    await vault.connect(safe).unlockMintingRights(lockId);

    for (const id of [9002n, 9003n, 9004n]) {
      expect(await vault.isMintingRightLocked(id)).to.be.false;
    }
  });

  it("overlapping tokenId in separate locks reverts correctly", async () => {
    await vault.connect(safe).lockMintingRights([9005n], "harvest", 0n);

    // Same tokenId in second lock must revert
    await expect(
      vault.connect(safe).lockMintingRights([9005n, 9006n], "credit", 0n)
    ).to.be.revertedWithCustomError(vault, "TokenIdAlreadyLocked")
      .withArgs(9005n);

    // 9006 should NOT be locked (transaction rolled back)
    expect(await vault.isMintingRightLocked(9006n)).to.be.false;
  });

  it("large batch of tokenIds: lockMintingRights handles array correctly", async () => {
    const ids = Array.from({ length: 50 }, (_, i) => BigInt(10000 + i));
    await expect(
      vault.connect(safe).lockMintingRights(ids, "harvest", 0n)
    ).to.not.be.reverted;

    expect(await vault.isMintingRightLocked(10000n)).to.be.true;
    expect(await vault.isMintingRightLocked(10049n)).to.be.true;
  });
});

// ================================================================
// EVENT INTEGRITY
// ================================================================
// SKIPPED — OBSOLETE API. Mixes valid minting-lock event checks with the removed
// EWBWhaleVault harvest-token events (HarvestTokenIssued / HarvestRecorded /
// issueHarvestToken / validateAndRecordHarvest) and the old 3-arg constructor.
// Harvest event integrity is covered by test/EWBNFTHarvestVault.test.js; minting
// events by the EWBWhaleVault suite. Retained for provenance.
describe.skip("Event Integrity — Exact Parameter Verification", () => {
  let vault, oracle;
  let safe, cold, deltaVault, user;

  beforeEach(async () => {
    [safe, cold, deltaVault, user] = await ethers.getSigners();
    oracle = await deployMockOracle(safe);
    const V = await ethers.getContractFactory("EWBWhaleVault");
    vault = await V.deploy(
      safe.address, cold.address, await oracle.getAddress());
    await vault.connect(safe).setDeltaVault(deltaVault.address);
    await vault.connect(safe).setTokenTiers([1001n],[0]); // EPIC
  });

  it("MintingRightsLocked: lockId increments correctly", async () => {
    const tx1 = await vault.connect(safe)
      .lockMintingRights([1001n], "harvest", 0n);
    const r1 = await tx1.wait();
    const ev1 = r1.logs.find(l =>
      l.fragment?.name === "MintingRightsLocked");
    expect(ev1.args[0]).to.equal(1n); // first lockId

    // Unlock and re-lock
    await vault.connect(safe).unlockMintingRights(1n);
    const tx2 = await vault.connect(safe)
      .lockMintingRights([1001n], "credit", 0n);
    const r2 = await tx2.wait();
    const ev2 = r2.logs.find(l =>
      l.fragment?.name === "MintingRightsLocked");
    expect(ev2.args[0]).to.equal(2n); // incremented
  });

  it("HarvestTokenIssued: expiresAt is exactly issuedAt + duration", async () => {
    const duration = 3600n;
    const tsBefore = BigInt(await getBlockTimestamp());

    const tx = await vault.connect(safe).issueHarvestToken(
      user.address, ethers.parseEther("315"), 0, duration);
    const receipt = await tx.wait();
    const ev = receipt.logs.find(l =>
      l.fragment?.name === "HarvestTokenIssued");

    const expiresAt = ev.args[3];
    // expiresAt should be between tsBefore+duration and tsBefore+duration+5
    expect(expiresAt).to.be.gte(tsBefore + duration);
    expect(expiresAt).to.be.lte(tsBefore + duration + 5n);
  });

  it("TierSet: emits correct tokenId and tier", async () => {
    await expect(vault.connect(safe).setTokenTiers([2001n],[2]))
      .to.emit(vault, "TierSet")
      .withArgs(2001n, 2);
  });

  it("MintingRightsUnlocked: emits correct lockId", async () => {
    await vault.connect(safe).lockMintingRights([3001n], "test", 0n);
    await expect(vault.connect(safe).unlockMintingRights(1n))
      .to.emit(vault, "MintingRightsUnlocked")
      .withArgs(1n, (v) => v > 0n);
  });

  it("HarvestRecorded: emits correct count after each harvest", async () => {
    await vault.connect(safe).issueHarvestToken(
      user.address, ethers.parseEther("1"), 3, 9999n);

    await expect(
      vault.connect(deltaVault).validateAndRecordHarvest(user.address))
      .to.emit(vault, "HarvestRecorded")
      .withArgs(user.address, 1n, (v) => v > 0n);

    await expect(
      vault.connect(deltaVault).validateAndRecordHarvest(user.address))
      .to.emit(vault, "HarvestRecorded")
      .withArgs(user.address, 2n, (v) => v > 0n);
  });
});

// ================================================================
// GAS / DoS VECTORS
// ================================================================
// SKIPPED — OBSOLETE API. Uses the old EWBWhaleVault 3-arg constructor and the
// removed harvest-token surface (issueHarvestToken, getVaultStats.harvestTokenCount).
// Batch-sizing / gas behaviour for minting locks is covered by the EWBWhaleVault
// suite and the Foundry fuzzing. Retained for provenance.
describe.skip("Gas and DoS Vectors", () => {
  let vault, oracle;
  let safe, cold;

  beforeEach(async () => {
    [safe, cold] = await ethers.getSigners();
    oracle = await deployMockOracle(safe);
    const V = await ethers.getContractFactory("EWBWhaleVault");
    vault = await V.deploy(
      safe.address, cold.address, await oracle.getAddress());
  });

  it("setTokenTiers: handles 100 tokens in one call", async () => {
    const ids   = Array.from({length:100}, (_,i) => BigInt(20000+i));
    const tiers = Array.from({length:100}, (_,i) => i % 4);
    await expect(vault.connect(safe).setTokenTiers(ids, tiers))
      .to.not.be.reverted;
  });

  it("lockMintingRights: handles 50 tokenIds", async () => {
    const ids = Array.from({length:50}, (_,i) => BigInt(30000+i));
    await expect(vault.connect(safe).lockMintingRights(ids, "harvest", 0n))
      .to.not.be.reverted;
  });

  it("multiple harvest tokens: issuing 10 tokens does not corrupt state", async () => {
    const signers = await ethers.getSigners();
    const deltaV  = signers[4];
    await vault.connect(safe).setDeltaVault(deltaV.address);

    for (let i = 5; i < 15; i++) {
      await vault.connect(safe).issueHarvestToken(
        signers[i].address, ethers.parseEther("1"), 3, 3600n);
    }
    const stats = await vault.getVaultStats();
    expect(stats.harvestTokenCount).to.equal(10n);
  });

  it("repeated lock/unlock does not corrupt totalLockedFaceETH", async () => {
    await vault.connect(safe).setTokenTiers([40001n],[0]); // EPIC 315 ETH

    for (let i = 0; i < 5; i++) {
      await vault.connect(safe).lockMintingRights([40001n], "test", 0n);
      const lockId = await vault.lockCount();
      await vault.connect(safe).unlockMintingRights(lockId);
    }

    const stats = await vault.getVaultStats();
    expect(stats.totalFaceETH).to.equal(0n); // Must be zero after all unlocks
  });
});

// ================================================================
// MULTI-ACTOR RACE CONDITIONS
// ================================================================
// SKIPPED — OBSOLETE API. Drives the removed EWBMintingRightsVault lending pool
// and KYC layer (4-arg constructor, depositSPV, submitKYCAttestation, openLoan,
// repayLoan, markDefault, liquidate). Multi-actor safety of the current
// borrow/repay flow is covered by the Foundry invariant suite. Retained for provenance.
describe.skip("Multi-Actor Race Condition Scenarios", () => {
  let mintingVault, oracle;
  let safe, cold, hardScan, borrower1, borrower2;

  beforeEach(async () => {
    [safe, cold, hardScan, borrower1, borrower2] =
      await ethers.getSigners();

    oracle = await deployMockOracle(safe);

    const MockWV = await ethers.getContractFactory("MockWhaleVault");
    const mockWV = await MockWV.deploy();
    await mockWV.setLocked([1001n,1002n,2001n,2002n], true);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("USD Coin","USDC",6);

    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    mintingVault = await MV.deploy(
      safe.address, cold.address,
      await mockWV.getAddress(),
      await oracle.getAddress()
    );

    await mintingVault.connect(safe).setHardScanAttestor(hardScan.address);

    // Seed pool
    const seed = ethers.parseUnits("500000",6);
    await usdc.mint(safe.address, seed * 2n);
    await usdc.connect(safe).approve(
      await mintingVault.getAddress(), ethers.MaxUint256);
    await mintingVault.connect(safe).depositSPV(seed);

    // Approve for borrowers
    await usdc.mint(borrower1.address, ethers.parseUnits("100000",6));
    await usdc.mint(borrower2.address, ethers.parseUnits("100000",6));
    await usdc.connect(borrower1).approve(
      await mintingVault.getAddress(), ethers.MaxUint256);
    await usdc.connect(borrower2).approve(
      await mintingVault.getAddress(), ethers.MaxUint256);
  });

  async function kycBorrower(borrower) {
    const ts    = BigInt(await getBlockTimestamp());
    const nonce = ethers.randomBytes(32);
    const kycId = `KYC-${borrower.address.slice(2,8)}`;
    const sig   = await signKYCAttestation(
      hardScan, borrower.address, kycId, ts, nonce);
    await mintingVault.connect(hardScan).submitKYCAttestation(
      borrower.address, kycId, ts, nonce, sig);
  }

  it("two borrowers open loans simultaneously without interference", async () => {
    await kycBorrower(borrower1);
    await kycBorrower(borrower2);

    const amount = ethers.parseUnits("1000",6);
    await mintingVault.connect(borrower1)
      .openLoan(1n, [1001n], amount);
    await mintingVault.connect(borrower2)
      .openLoan(2n, [2001n], amount);

    const loan1 = await mintingVault.getLoan(1n);
    const loan2 = await mintingVault.getLoan(2n);
    expect(loan1.active).to.be.true;
    expect(loan2.active).to.be.true;
    expect(loan1.borrower).to.equal(borrower1.address);
    expect(loan2.borrower).to.equal(borrower2.address);
  });

  it("repaying loan by non-borrower reverts cleanly", async () => {
    await kycBorrower(borrower1);
    const amount = ethers.parseUnits("1000",6);
    await mintingVault.connect(borrower1)
      .openLoan(1n, [1001n], amount);

    await expect(mintingVault.connect(borrower2).repayLoan(1n))
      .to.be.revertedWith("Not borrower");
  });

  it("double liquidation of same loan reverts on second call", async () => {
    await kycBorrower(borrower1);
    const amount = ethers.parseUnits("1000",6);
    await mintingVault.connect(borrower1)
      .openLoan(1n, [1001n], amount);
    await mintingVault.connect(safe).markDefault(1n);
    await mintingVault.connect(safe).liquidate(1n);

    // Second liquidation must revert — loan no longer active
    await expect(mintingVault.connect(safe).liquidate(1n))
      .to.be.revertedWithCustomError(mintingVault, "LoanNotActive");
  });

  it("KYC front-run: submit KYC then immediately open loan", async () => {
    // In same block context — KYC fresh, loan should succeed
    await kycBorrower(borrower1);
    const [fresh] = await mintingVault.isKYCFresh(borrower1.address);
    expect(fresh).to.be.true;

    await expect(
      mintingVault.connect(borrower1)
        .openLoan(1n, [1001n], ethers.parseUnits("100",6))
    ).to.not.be.reverted;
  });
});
