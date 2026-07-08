// test/BorrowLoop.test.js
// Full borrow-loop coverage for EWBMintingRightsVault (Track A — credit).
//
// Requested by Wayne before testnet deployment:
//   • borrowUSDC happy path (USDC delivered to the Ballet wallet)
//   • repayUSDC happy path (debt cleared, lock freed)
//   • double-borrow on the same lock reverts (LockAlreadyHasCredit)
//   • borrow above the tier LTV cap reverts (ExceedsLTVCap)
//   • the BALLET_WALLET recipient is asserted AND printed in the output
//
// This drives the REAL contracts end to end:
//   EWBWhaleVault.lockMintingRights  →  EWBMintingRightsVault.borrowUSDC / repayUSDC
// USDC (0xA0b8…) and the Aave v3 pool (0x8787…) are hard-coded in the vault, so
// mock bytecode is etched at those exact mainnet addresses; Aave "releases" USDC
// by pre-funding the vault, mirroring a real borrow.

const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  deployMockOracle, impersonateAccount, etchMock,
} = require("./helpers");

// Owner of both vaults is hard-coded to the Ballet wallet.
const BALLET_WALLET = "0xc82A59594560A3010F336ebe2e9CC4794DCD46cf";
// Hard-coded dependency addresses inside EWBMintingRightsVault.
const USDC_ADDR = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const AAVE_ADDR = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";

describe("EWBMintingRightsVault — full borrow loop (Track A)", () => {
  let whaleVault, mintingVault, oracle, usdc, aave, ballet;
  const TOKEN = 1001n;          // single EPIC minting right
  let mintingVaultAddr, creditLimit;

  beforeEach(async () => {
    // The Ballet wallet is the sole owner — impersonate + fund it for gas.
    ballet = await impersonateAccount(BALLET_WALLET);

    // floorETH = 0 disables the MEV snapshot deviation check on lock.
    oracle = await deployMockOracle(ballet, 0n);

    // Etch USDC + Aave v3 mocks at the addresses the vault hard-codes.
    usdc = await etchMock(USDC_ADDR, "MockERC20", "USD Coin", "USDC", 6);
    aave = await etchMock(AAVE_ADDR, "MockAaveV3Pool");
    await (await aave.setHealthFactor(ethers.parseEther("2"))).wait(); // healthy

    // Real WhaleVault — lock the minting right to mint a lockId with a face value.
    const WV = await ethers.getContractFactory("EWBWhaleVault", ballet);
    whaleVault = await WV.deploy(await oracle.getAddress());
    await (await whaleVault.connect(ballet).setTokenTiers([TOKEN], [0])).wait(); // TIER_EPIC
    await (await whaleVault.connect(ballet).lockMintingRights([TOKEN], "credit", 0n)).wait(); // lockId 1

    // Real MintingRightsVault reads the WhaleVault lock.
    const MV = await ethers.getContractFactory("EWBMintingRightsVault", ballet);
    mintingVault = await MV.deploy(await whaleVault.getAddress());
    mintingVaultAddr = await mintingVault.getAddress();

    // Simulate Aave holding USDC liquidity that the vault can draw and forward.
    await (await usdc.mint(mintingVaultAddr, 10n ** 30n)).wait();

    // Credit limit exactly as the contract computes it: faceValueUSD × min tier LTV.
    // Single EPIC token → LTV_EPIC = 3000 bps (30%).
    const faceUSD = await whaleVault.getLockFaceValueUSD(1n);
    creditLimit = (faceUSD * 3000n) / 10000n;
  });

  it("borrowUSDC delivers USDC to the Ballet wallet and records the credit", async () => {
    const amount = ethers.parseUnits("1000", 6); // $1,000, well under the cap
    const before = await usdc.balanceOf(BALLET_WALLET);

    await expect(mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], amount))
      .to.emit(mintingVault, "USDCBorrowed")
      .withArgs(1n, 1n, amount, creditLimit, BALLET_WALLET); // recipient == Ballet

    const after = await usdc.balanceOf(BALLET_WALLET);
    expect(after - before).to.equal(amount);

    // Explicit BALLET_WALLET address in the output, as requested.
    console.log("        → USDC recipient (BALLET_WALLET):", BALLET_WALLET);
    console.log("        → borrowed (6-dec):", amount.toString(),
                "| creditLimit (6-dec):", creditLimit.toString());

    const credit = await mintingVault.getCredit(1n);
    expect(credit.active).to.be.true;
    expect(credit.borrowed).to.equal(amount);
    expect(credit.lockId).to.equal(1n);
  });

  it("repayUSDC clears the debt and frees the lock", async () => {
    const amount = ethers.parseUnits("1000", 6);
    await (await mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], amount)).wait();

    // Ballet repays from its own USDC — fund + approve, then repay in full.
    await (await usdc.mint(BALLET_WALLET, amount)).wait();
    await (await usdc.connect(ballet).approve(mintingVaultAddr, amount)).wait();

    await expect(mintingVault.connect(ballet).repayUSDC(1n, amount))
      .to.emit(mintingVault, "USDCRepaid")
      .and.to.emit(mintingVault, "BorrowCapacityRestored").withArgs(1n);

    const credit = await mintingVault.getCredit(1n);
    expect(credit.active).to.be.false;
    expect(credit.borrowed).to.equal(0n);

    const stats = await mintingVault.vaultStats();
    console.log("        → totalBorrowed:", stats._borrowed.toString(),
                "| totalRepaid:", stats._repaid.toString(),
                "| net outstanding:", stats._net.toString());
    expect(stats._net).to.equal(0n);
  });

  it("double borrow on the same lock reverts (LockAlreadyHasCredit)", async () => {
    const amount = ethers.parseUnits("1000", 6);
    await (await mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], amount)).wait();

    await expect(mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], amount))
      .to.be.revertedWithCustomError(mintingVault, "LockAlreadyHasCredit")
      .withArgs(1n);
  });

  it("borrowing above the tier LTV cap reverts (ExceedsLTVCap)", async () => {
    const over = creditLimit + 1n;
    await expect(mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], over))
      .to.be.revertedWithCustomError(mintingVault, "ExceedsLTVCap")
      .withArgs(over, creditLimit);
  });

  it("borrowing exactly at the LTV cap succeeds (boundary)", async () => {
    await expect(mintingVault.connect(ballet).borrowUSDC(1n, [TOKEN], creditLimit))
      .to.not.be.reverted;
    const credit = await mintingVault.getCredit(1n);
    expect(credit.borrowed).to.equal(creditLimit);
  });

  it("only the Ballet wallet (owner) can borrow", async () => {
    const [, outsider] = await ethers.getSigners();
    await expect(
      mintingVault.connect(outsider).borrowUSDC(1n, [TOKEN], ethers.parseUnits("1", 6))
    ).to.be.revertedWithCustomError(mintingVault, "NotOwner");
  });
});
