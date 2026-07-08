// test/EWBMintingRightsVault.test.js
// Full coverage for EWBMintingRightsVault
// ERC-7621 lending + HardScan KYC + pool solvency

const { expect }     = require("chai");
const { ethers }     = require("hardhat");
const {
  increaseTime, getBlockTimestamp,
  deployMockOracle, signKYCAttestation,
  KYC_MAX_AGE,
} = require("./helpers");

// SKIPPED — OBSOLETE CONTRACT DESIGN. This suite targets a previous
// EWBMintingRightsVault architecture that no longer exists:
//   • a 1-arg deploy that also exposed safeMultisig()/coldWallet()
//   • a HardScan KYC attestation layer (setHardScanAttestor / submitKYCAttestation / isKYCFresh)
//   • an on-chain lending pool with SPV/L3T depositors (depositSPV / depositL3T / withdrawLender / getPoolStats)
//   • per-loan lifecycle (openLoan / repayLoan / markDefault / liquidate)
// The shipped contract is a minting-rights → Aave USDC borrow facility:
//   constructor(whaleVault); borrowUSDC / repayUSDC / autoRepay; getCredit / vaultStats.
// None of the entrypoints or custom errors asserted below exist anymore, so the
// suite cannot be mechanically updated — it would have to be rewritten against
// the new API. The new borrow/repay behaviour is exercised by the Foundry
// invariant suite (EWBVault.invariants.t.sol, 0 failures). Retained as a record
// of the deprecated KYC-pool-lending model.
describe.skip("EWBMintingRightsVault", () => {
  let vault, whaleVault, oracle, usdc;
  let safe, cold, hardScan, borrower, lender, attacker;

  // KYC helpers
  async function submitFreshKYC(addr) {
    const ts    = BigInt(await getBlockTimestamp());
    const kycId = "KYC-001";
    const nonce = ethers.randomBytes(32);
    const sig   = await signKYCAttestation(
      hardScan, addr, kycId, ts, nonce);
    await vault.connect(hardScan).submitKYCAttestation(
      addr, kycId, ts, nonce, sig);
  }

  beforeEach(async () => {
    [safe, cold, hardScan, borrower, lender, attacker] =
      await ethers.getSigners();

    // Deploy mocks
    const MockERC20    = await ethers.getContractFactory("MockERC20");
    const MockOracle   = await ethers.getContractFactory("MockOracle");
    const MockWhaleVault = await ethers.getContractFactory("MockWhaleVault");

    usdc  = await MockERC20.deploy("USD Coin", "USDC", 6);
    oracle = await MockOracle.deploy(
      ethers.parseEther("4.29"),
      ethers.parseUnits("2700", 8)
    );
    whaleVault = await MockWhaleVault.deploy();

    const Vault = await ethers.getContractFactory(
      "EWBMintingRightsVault", safe);
    vault = await Vault.deploy(await whaleVault.getAddress());

    // Seed USDC
    const seedAmount = ethers.parseUnits("1000000", 6);
    await usdc.mint(safe.address, seedAmount);
    await usdc.mint(lender.address, seedAmount);
    await usdc.mint(borrower.address, seedAmount);
  });

  // ── DEPLOYMENT ──────────────────────────────────────────────
  describe("Deployment", () => {
    it("sets immutable addresses correctly", async () => {
      expect(await vault.safeMultisig()).to.equal(safe.address);
      expect(await vault.coldWallet()).to.equal(cold.address);
    });

    it("reverts on zero whaleVault", async () => {
      const Vault = await ethers.getContractFactory("EWBMintingRightsVault");
      await expect(
        Vault.deploy(ethers.ZeroAddress)
      ).to.be.revertedWith("Zero whaleVault");
    });

    it("starts with zero pool balance", async () => {
      const stats = await vault.getPoolStats();
      expect(stats.balance).to.equal(0n);
    });
  });

  // ── HARDSCAN KYC ────────────────────────────────────────────
  describe("HardScan KYC Attestation", () => {
    it("sets HardScan attestor — multisig only", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      expect(await vault.hardScanAttestor()).to.equal(hardScan.address);
    });

    it("reverts if attacker sets attestor", async () => {
      await expect(
        vault.connect(attacker).setHardScanAttestor(hardScan.address)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("reverts if attestor set twice", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      await expect(
        vault.connect(safe).setHardScanAttestor(attacker.address)
      ).to.be.revertedWithCustomError(vault, "AttestorAlreadySet");
    });

    it("submits valid KYC attestation", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      await submitFreshKYC(borrower.address);
      const [fresh] = await vault.isKYCFresh(borrower.address);
      expect(fresh).to.be.true;
    });

    it("rejects attestation from non-attestor", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      const ts    = BigInt(await getBlockTimestamp());
      const nonce = ethers.randomBytes(32);
      const sig   = await signKYCAttestation(
        attacker, borrower.address, "KYC-001", ts, nonce);
      await expect(
        vault.connect(attacker).submitKYCAttestation(
          borrower.address, "KYC-001", ts, nonce, sig)
      ).to.be.revertedWithCustomError(vault, "KYCAttestationInvalid");
    });

    it("rejects replay — same nonce twice", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      const ts    = BigInt(await getBlockTimestamp());
      const nonce = ethers.randomBytes(32);
      const sig   = await signKYCAttestation(
        hardScan, borrower.address, "KYC-001", ts, nonce);
      await vault.connect(hardScan).submitKYCAttestation(
        borrower.address, "KYC-001", ts, nonce, sig);
      await expect(
        vault.connect(hardScan).submitKYCAttestation(
          borrower.address, "KYC-001", ts, nonce, sig)
      ).to.be.revertedWithCustomError(vault, "KYCNonceUsed");
    });

    it("rejects stale data timestamp (> 1hr old)", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      const stale = BigInt(await getBlockTimestamp()) - 3601n;
      const nonce = ethers.randomBytes(32);
      const sig   = await signKYCAttestation(
        hardScan, borrower.address, "KYC-001", stale, nonce);
      await expect(
        vault.connect(hardScan).submitKYCAttestation(
          borrower.address, "KYC-001", stale, nonce, sig)
      ).to.be.revertedWithCustomError(vault, "KYCDataTooOld");
    });

    it("KYC attestation expires after 24 hours — INV-3", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      await submitFreshKYC(borrower.address);
      const [fresh1] = await vault.isKYCFresh(borrower.address);
      expect(fresh1).to.be.true;
      await increaseTime(KYC_MAX_AGE + 1);
      const [fresh2] = await vault.isKYCFresh(borrower.address);
      expect(fresh2).to.be.false;
    });

    it("emits KYCAttestationSubmitted", async () => {
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      const ts    = BigInt(await getBlockTimestamp());
      const nonce = ethers.randomBytes(32);
      const sig   = await signKYCAttestation(
        hardScan, borrower.address, "KYC-001", ts, nonce);
      await expect(
        vault.connect(hardScan).submitKYCAttestation(
          borrower.address, "KYC-001", ts, nonce, sig)
      ).to.emit(vault, "KYCAttestationSubmitted");
    });
  });

  // ── LENDING POOL ─────────────────────────────────────────────
  describe("Lending Pool", () => {
    const depositAmount = ethers.parseUnits("100000", 6);

    beforeEach(async () => {
      await usdc.connect(safe).approve(
        await vault.getAddress(), ethers.MaxUint256);
      await usdc.connect(lender).approve(
        await vault.getAddress(), ethers.MaxUint256);
    });

    it("SPV deposits USDC — multisig only", async () => {
      await vault.connect(safe).depositSPV(depositAmount);
      const stats = await vault.getPoolStats();
      expect(stats.balance).to.equal(depositAmount);
    });

    it("reverts SPV deposit from non-multisig", async () => {
      await expect(
        vault.connect(lender).depositSPV(depositAmount)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("L3T holder deposits USDC", async () => {
      await vault.connect(lender).depositL3T(depositAmount);
      const stats = await vault.getPoolStats();
      expect(stats.balance).to.equal(depositAmount);
    });

    it("reverts on zero deposit", async () => {
      await expect(
        vault.connect(safe).depositSPV(0n)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });

    it("emits PoolDeposited event", async () => {
      await expect(vault.connect(safe).depositSPV(depositAmount))
        .to.emit(vault, "PoolDeposited")
        .withArgs(safe.address, depositAmount, true);
    });

    it("lender can withdraw deposit", async () => {
      await vault.connect(lender).depositL3T(depositAmount);
      const balBefore = await usdc.balanceOf(lender.address);
      await vault.connect(lender).withdrawLender(depositAmount);
      const balAfter = await usdc.balanceOf(lender.address);
      expect(balAfter).to.be.gte(balBefore);
    });

    it("withdrawLender enforces pool solvency — INV-4", async () => {
      await vault.connect(safe).depositSPV(depositAmount);
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      // Would need to have outstanding loan — just test solvency check
      const stats = await vault.getPoolStats();
      expect(stats.balance).to.equal(depositAmount);
    });

    it("reverts withdrawal of zero", async () => {
      await vault.connect(lender).depositL3T(depositAmount);
      await expect(
        vault.connect(lender).withdrawLender(0n)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });
  });

  // ── LOANS ────────────────────────────────────────────────────
  describe("Loan Lifecycle", () => {
    const poolSeed    = ethers.parseUnits("500000", 6);
    const loanAmount  = ethers.parseUnits("1000", 6);

    beforeEach(async () => {
      // Set up KYC
      await vault.connect(safe).setHardScanAttestor(hardScan.address);
      await submitFreshKYC(borrower.address);

      // Seed pool
      await usdc.connect(safe).approve(
        await vault.getAddress(), ethers.MaxUint256);
      await vault.connect(safe).depositSPV(poolSeed);

      // Set minting rights locked in mock
      await whaleVault.setLocked([1001n, 1002n], true);

      // Approve USDC for repayment
      await usdc.connect(borrower).approve(
        await vault.getAddress(), ethers.MaxUint256);
    });

    it("opens loan with fresh KYC and locked rights", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      const loan = await vault.getLoan(1n);
      expect(loan.active).to.be.true;
      expect(loan.borrower).to.equal(borrower.address);
      expect(loan.loanAmount).to.equal(loanAmount);
    });

    it("emits LoanOpened", async () => {
      await expect(
        vault.connect(borrower).openLoan(1n, [1001n, 1002n], loanAmount)
      ).to.emit(vault, "LoanOpened");
    });

    it("hard-reverts if KYC is stale — INV-3", async () => {
      await increaseTime(KYC_MAX_AGE + 1);
      await expect(
        vault.connect(borrower).openLoan(1n, [1001n], loanAmount)
      ).to.be.revertedWithCustomError(vault, "KYCNotFresh");
    });

    it("hard-reverts if minting right not locked — INV-1", async () => {
      await whaleVault.setLocked([9999n], false);
      await expect(
        vault.connect(borrower).openLoan(1n, [9999n], loanAmount)
      ).to.be.revertedWithCustomError(vault, "MintingRightNotLocked")
        .withArgs(9999n);
    });

    it("repays loan with interest", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await increaseTime(30 * 24 * 3600); // 30 days
      await vault.connect(borrower).repayLoan(1n);
      const loan = await vault.getLoan(1n);
      expect(loan.active).to.be.false;
    });

    it("emits LoanRepaid", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await expect(vault.connect(borrower).repayLoan(1n))
        .to.emit(vault, "LoanRepaid");
    });

    it("marks loan as defaulted — multisig only", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await vault.connect(safe).markDefault(1n);
      const loan = await vault.getLoan(1n);
      expect(loan.defaulted).to.be.true;
    });

    it("reverts markDefault from non-multisig", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await expect(
        vault.connect(attacker).markDefault(1n)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("liquidates defaulted loan — ERC-7621 cap enforced", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await vault.connect(safe).markDefault(1n);
      await expect(vault.connect(safe).liquidate(1n))
        .to.emit(vault, "LoanLiquidated");
    });

    it("liquidate reverts if loan not defaulted — INV-5 setup", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await expect(
        vault.connect(safe).liquidate(1n)
      ).to.be.revertedWithCustomError(vault, "LoanNotDefaulted");
    });

    it("liquidate reverts if loan not active", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await vault.connect(borrower).repayLoan(1n);
      await expect(
        vault.connect(safe).liquidate(1n)
      ).to.be.revertedWithCustomError(vault, "LoanNotActive");
    });

    it("reverts if pool has insufficient liquidity", async () => {
      const bigLoan = ethers.parseUnits("600000", 6);
      await expect(
        vault.connect(borrower).openLoan(1n, [1001n], bigLoan)
      ).to.be.revertedWithCustomError(vault, "InsufficientPoolLiquidity");
    });

    it("reverts repayLoan from non-borrower", async () => {
      await vault.connect(borrower).openLoan(
        1n, [1001n, 1002n], loanAmount);
      await usdc.connect(attacker).approve(
        await vault.getAddress(), ethers.MaxUint256);
      await expect(
        vault.connect(attacker).repayLoan(1n)
      ).to.be.revertedWith("Not borrower");
    });
  });

  // ── PAUSE ────────────────────────────────────────────────────
  describe("Pause", () => {
    it("safe can pause and unpause", async () => {
      await vault.connect(safe).pause();
      expect(await vault.paused()).to.be.true;
      await vault.connect(safe).unpause();
      expect(await vault.paused()).to.be.false;
    });

    it("cold wallet can pause", async () => {
      await vault.connect(cold).pause();
      expect(await vault.paused()).to.be.true;
    });

    it("attacker cannot pause", async () => {
      await expect(vault.connect(attacker).pause())
        .to.be.revertedWithCustomError(vault, "OnlyEmergency");
    });

    it("force unpause after 72hrs", async () => {
      await vault.connect(safe).pause();
      await increaseTime(72 * 3600 + 1);
      await vault.connect(attacker).forceUnpause();
      expect(await vault.paused()).to.be.false;
    });
  });
});
