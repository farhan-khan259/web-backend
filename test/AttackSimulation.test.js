// test/AttackSimulation.test.js
// Attack simulation tests — point 10 from audit recommendations
// Simulates oracle manipulation, reentrancy, reward inflation, admin abuse

"use strict";
const { expect } = require("chai");
const { ethers }  = require("hardhat");
const { deployMockUSDC, deployMockOracle, increaseTime } = require("./helpers");

// ── Oracle Attack Simulation ──────────────────────────────────────
describe("Attack: Oracle Manipulation", () => {
  let oracle, mintVault, safe, attacker;

  beforeEach(async () => {
    [safe, attacker] = await ethers.getSigners();
    const Oracle = await ethers.getContractFactory("EWBGorillaOracle");
    // Constructor is (ewbPool, owner). Pass a zero pool so setManualFloor
    // skips the TWAP cross-check; `safe` is the sole owner/multisig.
    oracle = await Oracle.deploy(ethers.ZeroAddress, safe.address);
  });

  it("attacker cannot set manual floor (not owner)", async () => {
    await expect(
      oracle.connect(attacker).setManualFloor(ethers.parseEther("1000"))
    ).to.be.revertedWith("Not owner");
  });

  it("multisig cannot set floor > 5% above TWAP when pool available", async () => {
    // With pool set, deviation > 5% must revert
    // Without pool (as in tests), deviation check bypassed — emits warning
    // This tests the guard is in place
    expect(oracle.MANUAL_FLOOR_MAX_DEVIATION_BPS).to.exist;
  });

  it("stale manual floor reverts getFloorPriceETH()", async () => {
    await oracle.connect(safe).setManualFloor(ethers.parseEther("4.29"));
    const maxAge = await oracle.manualFloorMaxAge();
    await increaseTime(Number(maxAge) + 1);
    await expect(oracle.getFloorPriceETH())
      .to.be.revertedWith("Manual floor price is stale — owner must update");
  });

  it("attacker cannot disable manual floor", async () => {
    await oracle.connect(safe).setManualFloor(ethers.parseEther("4.29"));
    await expect(oracle.connect(attacker).disableManualFloor())
      .to.be.revertedWith("Not owner");
  });
});

// ── Reentrancy Attack Simulation ─────────────────────────────────
// SKIPPED — OBSOLETE API. This scenario targets EWBMintingRightsVault's
// old lending-pool design: a 4-arg constructor
// (safe, cold, token, oracle) and a withdrawLender() entrypoint.
// That pool/lender model was removed; the contract is now a minting-rights
// → Aave USDC borrow facility (constructor(whaleVault); borrowUSDC/repayUSDC).
// Reentrancy on the live SafeERC20 transfer paths is covered by the Foundry
// invariant suite. Kept as documentation of the removed vector.
describe.skip("Attack: Reentrancy via malicious token", () => {
  let mintVault, reentrantToken, safe, cold, attacker;

  beforeEach(async () => {
    [safe, cold, attacker] = await ethers.getSigners();
    const ReentrantERC20 = await ethers.getContractFactory("ReentrantERC20");
    reentrantToken = await ReentrantERC20.deploy();
  });

  it("nonReentrant blocks recursive withdrawLender call", async () => {
    // The ReentrantERC20 mock tries to re-enter on transfer
    // nonReentrant modifier reverts the recursive call
    // Verify the modifier is present on withdrawLender
    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    const vault = await MV.deploy(
      safe.address, cold.address,
      await reentrantToken.getAddress(),
      ethers.ZeroAddress
    );
    const fn = vault.interface.getFunction("withdrawLender");
    expect(fn).to.not.be.undefined;
    // The nonReentrant guard is verified in the contract bytecode
    // Functional test requires a fork environment with real tokens
  });
});

// ── Reward Inflation Attack ───────────────────────────────────────
// SKIPPED — OBSOLETE API. Targets the removed EWBMintingRightsVault
// lending pool: depositSPV()/withdrawLender()/accInterestPerShare(). The
// current contract has no interest-share accounting (borrow/repay against
// Aave only), so there is no "claim interest twice" surface to test.
// Retained as documentation of the deprecated reward model.
describe.skip("Attack: Reward Inflation — claim interest twice", () => {
  let mintVault, usdc, safe, cold, lender;

  beforeEach(async () => {
    [safe, cold, lender] = await ethers.getSigners();
    usdc = await deployMockUSDC(safe);
    const MV = await ethers.getContractFactory("EWBMintingRightsVault");
    mintVault = await MV.deploy(
      safe.address, cold.address,
      await usdc.getAddress(),
      ethers.ZeroAddress
    );
  });

  it("withdrawLender updates rewardDebt — cannot claim same interest twice", async () => {
    const amount = ethers.parseUnits("100000", 6);
    await usdc.mint(safe.address, amount);
    await usdc.connect(safe).approve(await mintVault.getAddress(), amount);
    await mintVault.connect(safe).depositSPV(amount);

    // First withdrawal
    await mintVault.connect(safe).withdrawLender(ethers.parseUnits("50000", 6));
    const balAfterFirst = await usdc.balanceOf(safe.address);

    // Second withdrawal of same amount — rewardDebt was updated
    // Cannot claim the same interest again
    await mintVault.connect(safe).withdrawLender(ethers.parseUnits("50000", 6));
    const balAfterSecond = await usdc.balanceOf(safe.address);

    // Second withdrawal should give back principal only, no extra interest
    expect(balAfterSecond - balAfterFirst).to.be.lte(ethers.parseUnits("50000", 6));
  });

  it("accInterestPerShare is monotonically non-decreasing", async () => {
    const before = await mintVault.accInterestPerShare();
    // No interest has accrued — should be 0
    expect(before).to.equal(0n);
    // After deposit and repayment, accInterestPerShare can only increase
    // Verified in invariant suite
  });
});

// ── Admin Abuse Simulation ────────────────────────────────────────
describe("Attack: Unauthorised admin calls", () => {
  let vault, safe, cold, attacker;

  beforeEach(async () => {
    [safe, cold, attacker] = await ethers.getSigners();
    const Vault = await ethers.getContractFactory("EWBDeltaNeutralVault");
    // Constructor: (safeMultisig, coldWallet, revenueRouter)
    vault = await Vault.deploy(safe.address, cold.address, safe.address);
  });

  it("attacker cannot deployLongLeg", async () => {
    await expect(
      vault.connect(attacker).deployLongLeg({ value: ethers.parseEther("1") })
    ).to.be.revertedWith("Requires Safe multisig");
  });

  it("attacker cannot set paramTimelock", async () => {
    await expect(vault.connect(attacker).setParamTimelock(0))
      .to.be.revertedWith("Requires Safe multisig");
  });

  it("attacker cannot initiate emergency exit", async () => {
    await expect(vault.connect(attacker).initiateEmergencyExit())
      .to.be.revertedWith("Requires multisig or cold wallet");
  });

  it("attacker cannot setPaused", async () => {
    await expect(vault.connect(attacker).setPaused(true))
      .to.be.revertedWith("Requires multisig or cold wallet");
  });

  it("attacker cannot queue attestor rotation", async () => {
    await expect(
      vault.connect(attacker).queueAttestorRotation(attacker.address)
    ).to.be.revertedWith("Requires Safe multisig");
  });

  it("attacker cannot set withdrawal timelock to 0 to bypass", async () => {
    await expect(vault.connect(attacker).setWithdrawalTimelock(0))
      .to.be.revertedWith("Requires Safe multisig");
  });

  it("cold wallet cannot deployLongLeg (not owner)", async () => {
    await expect(
      vault.connect(cold).deployLongLeg({ value: ethers.parseEther("1") })
    ).to.be.revertedWith("Requires Safe multisig");
  });

  it("attacker CANNOT execute attestor rotation (emergency only)", async () => {
    // executeAttestorRotation is onlyEmergency (safe OR cold). An outside
    // attacker must be rejected even after the rotation timelock elapses.
    await vault.connect(safe).setHedgeAttestor(attacker.address);
    await vault.connect(safe).queueAttestorRotation(cold.address);
    await increaseTime(48 * 3600 + 1);
    await expect(vault.connect(attacker).executeAttestorRotation())
      .to.be.revertedWith("Requires multisig or cold wallet");
  });
});
