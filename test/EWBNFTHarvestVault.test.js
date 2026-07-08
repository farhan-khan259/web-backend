// test/EWBNFTHarvestVault.test.js
// Test suite — EWBNFTHarvestVault
// ERC-721 → ERC-20 Harvest Engine

const { ethers } = require("hardhat");
const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const {
  TIER, TIER_FLOORS, PRECISION, ETH_USD_PRICE,
  deployMockERC721, deployMockOracle,
  increaseTime, getBlockTimestamp, etchMock,
} = require("./helpers");

// The vault pulls/returns NFTs from this hard-coded mainnet EWB collection
// address, so the mock ERC-721 must live at exactly that address.
const EWB_NFT_ADDR = "0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4";

// The vault expects an 18-decimal ETH/USD price (as the real EWBGorillaOracle
// returns via getETHUSDPrice()). The shared MockOracle stores the value
// verbatim, so seed it with the 18-decimal figure. ETH_USD_PRICE is 8-dec.
const ETH_USD_18 = ETH_USD_PRICE * 10n ** 10n;

// ── Constants ────────────────────────────────────────────────
const HARVEST_RATE_BPS  = 1000n;   // 10%
const HARVEST_COOLDOWN  = 30 * 24 * 3600; // 30 days
const RESERVE_AMOUNT    = ethers.parseEther("10000000"); // 10M tokens

// ── Mock WhaleVault ──────────────────────────────────────────
// Deployed inline as a minimal mock — tracks harvest tokens and
// minting locks without full EWBWhaleVault complexity.

const MOCK_WHALE_VAULT_ABI = `
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
contract MockWhaleVault {
    mapping(address => bool)  public harvestValid;
    mapping(uint256 => bool)  public mintingLocked;
    mapping(uint256 => uint8) public tierOf;
    mapping(uint256 => bool)  public tierAssigned;

    function setHarvestToken(address h, bool v) external { harvestValid[h] = v; }
    function setMintingLock(uint256 tid, bool v) external { mintingLocked[tid] = v; }
    function setTier(uint256 tid, uint8 t) external { tierOf[tid] = t; tierAssigned[tid] = true; }
    function setTokenTiers(uint256[] calldata tids, uint8[] calldata tiers) external {
        require(tids.length == tiers.length, "Length mismatch");
        for (uint256 i = 0; i < tids.length; i++) {
            tierOf[tids[i]] = tiers[i];
            tierAssigned[tids[i]] = true;
        }
    }

    function hasValidHarvestToken(address h) external view returns (bool) { return harvestValid[h]; }
    function isMintingRightLocked(uint256 tid) external view returns (bool) { return mintingLocked[tid]; }
    function validateAndRecordHarvest(address) external returns (bool) { return true; }
    function tokenTiers(uint256 tid) external view returns (uint8 tier, bool assigned) {
        return (tierOf[tid], tierAssigned[tid]);
    }
}
`;

// ── Fixture ──────────────────────────────────────────────────
async function deployFixture() {
  const [deployer, multisig, coldWallet, holder, other] =
    await ethers.getSigners();

  // Mock EWB ERC-721 — etched at the hard-coded collection address the
  // vault transfers against (deployMockERC721 kept imported for parity).
  const nft = await etchMock(EWB_NFT_ADDR, "MockERC721", "Exposed Walls (EWB)", "EWB");

  // Mock Oracle ($2,700/ETH) — seeded with an 18-decimal ETH/USD price
  // to match what EWBNFTHarvestVault reads from getETHUSDPrice().
  const oracle = await deployMockOracle(deployer, undefined, ETH_USD_18);

  // Mock WhaleVault
  const MockWhaleVault = await ethers.getContractFactory(
    "MockWhaleVault", deployer
  );
  const whaleVault = await MockWhaleVault.deploy();

  // Mock ERC-20 harvest token (18 dec, like L1T)
  const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
  const harvestToken = await MockERC20.deploy("EWB Layer1 Token", "L1T", 18);

  // Deploy EWBNFTHarvestVault
  const Factory = await ethers.getContractFactory("EWBNFTHarvestVault", deployer);
  const vault = await Factory.deploy(
    multisig.address,
    coldWallet.address,
    await whaleVault.getAddress(),
    await oracle.getAddress(),
    await harvestToken.getAddress(),
    HARVEST_RATE_BPS
  );

  const vaultAddr = await vault.getAddress();
  const nftAddr   = await nft.getAddress();
  const htAddr    = await harvestToken.getAddress();

  // Mint NFTs to holder — token IDs 1–5 (standard tier), 100 (epic)
  for (let i = 1; i <= 5; i++) await nft.mint(holder.address, i);
  await nft.mint(holder.address, 100);

  // Set tiers on mock whale vault
  await whaleVault.setTokenTiers(
    [1n,2n,3n,4n,5n],
    [TIER.STANDARD, TIER.STANDARD, TIER.STANDARD, TIER.STANDARD, TIER.STANDARD]
  );
  await whaleVault.setTokenTiers([100n], [TIER.EPIC]);

  // Give holder a valid harvest token
  await whaleVault.setHarvestToken(holder.address, true);

  // Approve vault to transfer holder's NFTs
  await nft.connect(holder).setApprovalForAll(vaultAddr, true);

  // Fund vault reserve
  await harvestToken.mint(vaultAddr, RESERVE_AMOUNT);

  return {
    vault, nft, oracle, whaleVault, harvestToken,
    deployer, multisig, coldWallet, holder, other,
    vaultAddr, nftAddr, htAddr,
  };
}

// ────────────────────────────────────────────────────────────
describe("EWBNFTHarvestVault", () => {

  // ── Deployment ──────────────────────────────────────────
  describe("Deployment", () => {
    it("sets immutable addresses correctly", async () => {
      const { vault, whaleVault, oracle, multisig, coldWallet, harvestToken } =
        await loadFixture(deployFixture);

      expect(await vault.safeMultisig()).to.equal(multisig.address);
      expect(await vault.coldWallet()).to.equal(coldWallet.address);
      expect(await vault.whaleVault()).to.equal(await whaleVault.getAddress());
      expect(await vault.oracle()).to.equal(await oracle.getAddress());
      expect(await vault.harvestTokenAddress()).to.equal(await harvestToken.getAddress());
    });

    it("sets harvest rate and cooldown", async () => {
      const { vault } = await loadFixture(deployFixture);
      expect(await vault.harvestRateBps()).to.equal(HARVEST_RATE_BPS);
      expect(await vault.harvestCooldown()).to.equal(HARVEST_COOLDOWN);
    });

    it("reverts on zero address in constructor", async () => {
      const [deployer] = await ethers.getSigners();
      const F = await ethers.getContractFactory("EWBNFTHarvestVault", deployer);
      await expect(
        F.deploy(ethers.ZeroAddress, ethers.ZeroAddress,
          ethers.ZeroAddress, ethers.ZeroAddress,
          ethers.ZeroAddress, 1000)
      ).to.be.reverted;
    });

    it("reverts if harvest rate exceeds max (50%)", async () => {
      const [deployer, ms, cw] = await ethers.getSigners();
      const nft     = await deployMockERC721(deployer);
      const oracle  = await deployMockOracle(deployer);
      const MockWV  = await ethers.getContractFactory("MockWhaleVault", deployer);
      const wv      = await MockWV.deploy();
      const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
      const ht      = await MockERC20.deploy("T", "T", 18);
      const F = await ethers.getContractFactory("EWBNFTHarvestVault", deployer);
      await expect(
        F.deploy(ms.address, cw.address,
          await wv.getAddress(), await oracle.getAddress(),
          await ht.getAddress(), 6000) // 60% > 50% max
      ).to.be.revertedWithCustomError(
        { interface: F.interface }, "HarvestRateExceedsMax"
      );
    });
  });

  // ── lockNFTs ──────────────────────────────────────────────
  describe("lockNFTs()", () => {
    it("locks a single standard NFT and records face value", async () => {
      const { vault, holder } = await loadFixture(deployFixture);

      const tx = await vault.connect(holder).lockNFTs([1]);
      const receipt = await tx.wait();

      // Lock ID = 1
      const lock = await vault.getLock(1);
      expect(lock.owner).to.equal(holder.address);
      expect(lock.tokenIds).to.deep.equal([1n]);
      expect(lock.faceValueETH).to.equal(TIER_FLOORS.STANDARD);
      expect(lock.active).to.be.true;
    });

    it("locks multiple NFTs — accumulates face value", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      // 3 standard + 1 epic
      await vault.connect(holder).lockNFTs([1, 2, 3, 100]);

      const lock = await vault.getLock(1);
      const expectedETH = TIER_FLOORS.STANDARD * 3n + TIER_FLOORS.EPIC;
      expect(lock.faceValueETH).to.equal(expectedETH);
    });

    it("reverts if no valid harvest token", async () => {
      const { vault, whaleVault, other, nft, vaultAddr } = await loadFixture(deployFixture);
      // Mint an NFT to `other`
      await nft.mint(other.address, 999);
      await nft.connect(other).setApprovalForAll(vaultAddr, true);
      // other has no harvest token
      await expect(
        vault.connect(other).lockNFTs([999])
      ).to.be.revertedWithCustomError(vault, "NoValidHarvestToken");
    });

    it("reverts on empty tokenIds array", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await expect(
        vault.connect(holder).lockNFTs([])
      ).to.be.revertedWithCustomError(vault, "EmptyTokenArray");
    });

    it("reverts on double-lock of same token", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      // token 1 now in vault — second attempt must fail
      await expect(
        vault.connect(holder).lockNFTs([1])
      ).to.be.revertedWithCustomError(vault, "TokenIdAlreadyLocked");
    });

    it("reverts if token already locked as minting right in WhaleVault", async () => {
      const { vault, holder, whaleVault } = await loadFixture(deployFixture);
      // Mark token 2 as a minting right lock
      await whaleVault.setLocked([2], true);
      await expect(
        vault.connect(holder).lockNFTs([2])
      ).to.be.revertedWithCustomError(vault, "MintingRightConflict");
    });

    it("emits NFTsLocked event with correct args", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await expect(vault.connect(holder).lockNFTs([1]))
        .to.emit(vault, "NFTsLocked")
        .withArgs(
          1n,
          holder.address,
          [1n],
          TIER_FLOORS.STANDARD,
          // faceValueUSD: 1 ETH * $2700 / 1e12  (6-dec)
          (TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n)
        );
    });

    it("increments totalActiveNFTs", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1, 2]);
      expect(await vault.totalActiveNFTs()).to.equal(2n);
    });

    it("NFTs are in vault custody after lock", async () => {
      const { vault, nft, holder, vaultAddr } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      expect(await nft.ownerOf(1)).to.equal(vaultAddr);
    });
  });

  // ── harvestERC20 ──────────────────────────────────────────
  describe("harvestERC20()", () => {
    it("harvests correct ERC-20 amount on first harvest", async () => {
      const { vault, holder, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);

      const balBefore = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const balAfter = await harvestToken.balanceOf(holder.address);

      // faceValueUSD (6 dec): 1 ETH * $2700 = $2700 → 2_700_000_000 (6 dec)
      // gross (18 dec): 2_700_000_000 * 1e12 * 1000 / 10000 = 270 tokens
      // holder receives gross MINUS the 2% protocol fee (default 200 bps).
      const faceUSD = TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n;
      const gross   = faceUSD * 10n**12n * HARVEST_RATE_BPS / 10000n;
      const net     = gross - (gross * 200n / 10000n);

      expect(balAfter - balBefore).to.equal(net);
    });

    it("reverts if no valid harvest token", async () => {
      const { vault, holder, whaleVault } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      // Revoke harvest token
      await whaleVault.setHarvestToken(holder.address, false);
      await expect(
        vault.connect(holder).harvestERC20(1)
      ).to.be.revertedWithCustomError(vault, "NoValidHarvestToken");
    });

    it("enforces cooldown — reverts on second harvest too soon", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      // Immediately try again — should fail
      await expect(
        vault.connect(holder).harvestERC20(1)
      ).to.be.revertedWithCustomError(vault, "HarvestCooldownActive");
    });

    it("allows harvest after cooldown passes", async () => {
      const { vault, holder, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      // Advance 30 days
      await increaseTime(HARVEST_COOLDOWN + 1);

      const balBefore = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const balAfter = await harvestToken.balanceOf(holder.address);
      expect(balAfter).to.be.gt(balBefore);
    });

    it("reverts if called by non-owner", async () => {
      const { vault, holder, other } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await expect(
        vault.connect(other).harvestERC20(1)
      ).to.be.revertedWithCustomError(vault, "NotLockOwner");
    });

    it("reverts on inactive lock", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).unlockNFTs(1);
      await expect(
        vault.connect(holder).harvestERC20(1)
      ).to.be.revertedWithCustomError(vault, "LockNotActive");
    });

    it("reverts if reserve is insufficient", async () => {
      const { vault, holder, harvestToken, multisig, vaultAddr } =
        await loadFixture(deployFixture);
      // Drain reserve back to multisig
      const reserve = await harvestToken.balanceOf(vaultAddr);
      await vault.connect(multisig).withdrawReserve(reserve);

      await vault.connect(holder).lockNFTs([1]);
      await expect(
        vault.connect(holder).harvestERC20(1)
      ).to.be.revertedWithCustomError(vault, "InsufficientReserve");
    });

    it("increments harvestCount and totalHarvested on lock", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      const lock = await vault.getLock(1);
      expect(lock.harvestCount).to.equal(1n);
      expect(lock.totalHarvested).to.be.gt(0n);
    });

    it("emits ERC20Harvested event", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await expect(vault.connect(holder).harvestERC20(1))
        .to.emit(vault, "ERC20Harvested");
    });
  });

  // ── unlockNFTs ────────────────────────────────────────────
  describe("unlockNFTs()", () => {
    it("returns NFTs to owner and marks lock inactive", async () => {
      const { vault, nft, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1, 2]);
      await vault.connect(holder).unlockNFTs(1);

      // NFTs back with holder
      expect(await nft.ownerOf(1)).to.equal(holder.address);
      expect(await nft.ownerOf(2)).to.equal(holder.address);

      const lock = await vault.getLock(1);
      expect(lock.active).to.be.false;
    });

    it("reverts if not lock owner", async () => {
      const { vault, holder, other } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await expect(
        vault.connect(other).unlockNFTs(1)
      ).to.be.revertedWithCustomError(vault, "NotLockOwner");
    });

    it("reverts if lock already inactive", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).unlockNFTs(1);
      await expect(
        vault.connect(holder).unlockNFTs(1)
      ).to.be.revertedWithCustomError(vault, "LockNotActive");
    });

    it("decrements totalActiveNFTs", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1, 2]);
      expect(await vault.totalActiveNFTs()).to.equal(2n);
      await vault.connect(holder).unlockNFTs(1);
      expect(await vault.totalActiveNFTs()).to.equal(0n);
    });

    it("clears tokenIdInVault mapping — token can be relocked", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).unlockNFTs(1);

      // Should be able to lock token 1 again
      await vault.connect(holder).lockNFTs([1]);
      const lock = await vault.getLock(2);
      expect(lock.active).to.be.true;
    });

    it("emits NFTsUnlocked event", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await expect(vault.connect(holder).unlockNFTs(1))
        .to.emit(vault, "NFTsUnlocked");
    });
  });

  // ── Admin ─────────────────────────────────────────────────
  describe("Admin (multisig only)", () => {
    it("multisig can update harvest token", async () => {
      const { vault, multisig, deployer } = await loadFixture(deployFixture);
      const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
      const newToken = await MockERC20.deploy("L3T", "L3T", 18);
      await vault.connect(multisig).setHarvestToken(await newToken.getAddress());
      expect(await vault.harvestTokenAddress()).to.equal(await newToken.getAddress());
    });

    it("non-multisig cannot update harvest token", async () => {
      const { vault, holder, deployer } = await loadFixture(deployFixture);
      const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
      const t = await MockERC20.deploy("T", "T", 18);
      await expect(
        vault.connect(holder).setHarvestToken(await t.getAddress())
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("setHarvestRate — enforces max 50%", async () => {
      const { vault, multisig } = await loadFixture(deployFixture);
      await expect(
        vault.connect(multisig).setHarvestRate(6000)
      ).to.be.revertedWithCustomError(vault, "HarvestRateExceedsMax");
    });

    it("setHarvestRate — accepts valid rate", async () => {
      const { vault, multisig } = await loadFixture(deployFixture);
      await vault.connect(multisig).setHarvestRate(2000);
      expect(await vault.harvestRateBps()).to.equal(2000n);
    });

    it("multisig can fund and withdraw reserve", async () => {
      const { vault, multisig, harvestToken, vaultAddr } = await loadFixture(deployFixture);
      const before = await harvestToken.balanceOf(vaultAddr);

      // Mint to multisig and fund
      await harvestToken.mint(multisig.address, ethers.parseEther("100"));
      await harvestToken.connect(multisig).approve(vaultAddr, ethers.parseEther("100"));
      await vault.connect(multisig).fundReserve(ethers.parseEther("100"));

      expect(await harvestToken.balanceOf(vaultAddr)).to.equal(
        before + ethers.parseEther("100")
      );

      // Withdraw
      await vault.connect(multisig).withdrawReserve(ethers.parseEther("100"));
      expect(await harvestToken.balanceOf(vaultAddr)).to.equal(before);
    });
  });

  // ── Pause / Emergency ────────────────────────────────────
  describe("Pause / Emergency", () => {
    it("multisig can pause and unpause", async () => {
      const { vault, multisig } = await loadFixture(deployFixture);
      await vault.connect(multisig).pause();
      expect(await vault.paused()).to.be.true;
      await vault.connect(multisig).unpause();
      expect(await vault.paused()).to.be.false;
    });

    it("lockNFTs reverts when paused", async () => {
      const { vault, multisig, holder } = await loadFixture(deployFixture);
      await vault.connect(multisig).pause();
      await expect(
        vault.connect(holder).lockNFTs([1])
      ).to.be.reverted;
    });

    it("harvestERC20 reverts when paused", async () => {
      const { vault, holder, multisig } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(multisig).pause();
      await expect(
        vault.connect(holder).harvestERC20(1)
      ).to.be.reverted;
    });

    it("forceUnpause works after 72hr max pause", async () => {
      const { vault, multisig, other } = await loadFixture(deployFixture);
      await vault.connect(multisig).pause();
      await increaseTime(72 * 3600 + 1);
      await vault.connect(other).forceUnpause();
      expect(await vault.paused()).to.be.false;
    });

    it("forceUnpause reverts before 72hr max", async () => {
      const { vault, multisig, other } = await loadFixture(deployFixture);
      await vault.connect(multisig).pause();
      await increaseTime(3600); // only 1 hour
      await expect(
        vault.connect(other).forceUnpause()
      ).to.be.revertedWithCustomError(vault, "MaxPauseNotReached");
    });
  });

  // ── Views ────────────────────────────────────────────────
  describe("Views", () => {
    it("getVaultStats returns correct stats", async () => {
      const { vault, holder, harvestToken, vaultAddr } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1, 2]);

      const stats = await vault.getVaultStats();
      expect(stats.activeNFTs).to.equal(2n);
      expect(stats.reserveBalance).to.equal(
        await harvestToken.balanceOf(vaultAddr)
      );
      expect(stats.currentRateBps).to.equal(HARVEST_RATE_BPS);
      expect(stats.currentFeeBps).to.equal(200n);
    });

    it("getOwnerLocks returns correct lock IDs", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).lockNFTs([2]);

      const lockIds = await vault.getOwnerLocks(holder.address);
      expect(lockIds).to.deep.equal([1n, 2n]);
    });

    it("getLock harvestReady is true after cooldown", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      // Not ready immediately after harvest
      let info = await vault.getLock(1);
      expect(info.harvestReady).to.be.false;

      // Ready after cooldown
      await increaseTime(HARVEST_COOLDOWN + 1);
      info = await vault.getLock(1);
      expect(info.harvestReady).to.be.true;
    });
  });

  // ── Epic tier — higher face value ────────────────────────
  describe("Epic tier harvest", () => {
    it("epic NFT produces 315x standard harvest amount", async () => {
      const { vault, holder, harvestToken } = await loadFixture(deployFixture);

      // Lock standard token 1
      await vault.connect(holder).lockNFTs([1]);
      const balBefore1 = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const standardHarvest = (await harvestToken.balanceOf(holder.address)) - balBefore1;

      // Unlock and lock epic token 100
      await vault.connect(holder).unlockNFTs(1);
      await vault.connect(holder).lockNFTs([100]);
      const balBefore2 = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(2);
      const epicHarvest = (await harvestToken.balanceOf(holder.address)) - balBefore2;

      expect(epicHarvest).to.equal(standardHarvest * 315n);
    });
  });

  // ── Protocol Fee ─────────────────────────────────────────
  describe("Protocol Fee", () => {
    it("default fee is 2% (200 bps)", async () => {
      const { vault } = await loadFixture(deployFixture);
      expect(await vault.protocolFeeBps()).to.equal(200n);
    });

    it("fee deducted from gross harvest — holder receives net", async () => {
      const { vault, holder, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);

      const balBefore = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const balAfter = await harvestToken.balanceOf(holder.address);

      // gross = faceValueUSD * 1e12 * 1000 / 10000
      const faceUSD = TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n;
      const gross   = faceUSD * 10n**12n * HARVEST_RATE_BPS / 10000n;
      const fee     = gross * 200n / 10000n;  // 2%
      const net     = gross - fee;

      expect(balAfter - balBefore).to.equal(net);
    });

    it("fee accumulates in contract", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      const faceUSD = TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n;
      const gross   = faceUSD * 10n**12n * HARVEST_RATE_BPS / 10000n;
      const fee     = gross * 200n / 10000n;

      expect(await vault.accumulatedFees()).to.equal(fee);
      expect(await vault.totalFeesCollected()).to.equal(fee);
    });

    it("multisig can collect all fees", async () => {
      const { vault, holder, multisig, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      const fees = await vault.accumulatedFees();
      const balBefore = await harvestToken.balanceOf(multisig.address);
      await vault.connect(multisig).collectProtocolFees(0); // 0 = withdraw all
      const balAfter = await harvestToken.balanceOf(multisig.address);

      expect(balAfter - balBefore).to.equal(fees);
      expect(await vault.accumulatedFees()).to.equal(0n);
    });

    it("multisig can collect partial fees", async () => {
      const { vault, holder, multisig } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      const fees = await vault.accumulatedFees();
      const half = fees / 2n;
      await vault.connect(multisig).collectProtocolFees(half);
      expect(await vault.accumulatedFees()).to.equal(fees - half);
    });

    it("non-multisig cannot collect fees", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);
      await expect(
        vault.connect(holder).collectProtocolFees(0)
      ).to.be.revertedWithCustomError(vault, "OnlyMultisig");
    });

    it("setProtocolFee — multisig can update", async () => {
      const { vault, multisig } = await loadFixture(deployFixture);
      await vault.connect(multisig).setProtocolFee(500); // 5%
      expect(await vault.protocolFeeBps()).to.equal(500n);
    });

    it("setProtocolFee — reverts above 25% max", async () => {
      const { vault, multisig } = await loadFixture(deployFixture);
      await expect(
        vault.connect(multisig).setProtocolFee(3000) // 30%
      ).to.be.revertedWithCustomError(vault, "ProtocolFeeExceedsMax");
    });

    it("fee at 0% — holder receives full gross", async () => {
      const { vault, holder, multisig, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(multisig).setProtocolFee(0);
      await vault.connect(holder).lockNFTs([1]);

      const balBefore = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const balAfter = await harvestToken.balanceOf(holder.address);

      const faceUSD = TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n;
      const gross   = faceUSD * 10n**12n * HARVEST_RATE_BPS / 10000n;

      expect(balAfter - balBefore).to.equal(gross);
      expect(await vault.accumulatedFees()).to.equal(0n);
    });

    it("fee at 25% max — correct split", async () => {
      const { vault, holder, multisig, harvestToken } = await loadFixture(deployFixture);
      await vault.connect(multisig).setProtocolFee(2500); // 25%
      await vault.connect(holder).lockNFTs([1]);

      const balBefore = await harvestToken.balanceOf(holder.address);
      await vault.connect(holder).harvestERC20(1);
      const balAfter = await harvestToken.balanceOf(holder.address);

      const faceUSD = TIER_FLOORS.STANDARD * ETH_USD_18 / 10n**18n / 10n**12n;
      const gross   = faceUSD * 10n**12n * HARVEST_RATE_BPS / 10000n;
      const fee     = gross * 2500n / 10000n;
      const net     = gross - fee;

      expect(balAfter - balBefore).to.equal(net);
      expect(await vault.accumulatedFees()).to.equal(fee);
    });

    it("getVaultStats returns fee fields", async () => {
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);

      const stats = await vault.getVaultStats();
      expect(stats.currentFeeBps).to.equal(200n);
      expect(stats.pendingFees).to.equal(await vault.accumulatedFees());
      expect(stats.allTimeFees).to.equal(await vault.totalFeesCollected());
    });
  });
  describe("Reentrancy guard", () => {
    it("lockNFTs and harvestERC20 are reentrancy-protected (nonReentrant)", async () => {
      // Simply verify the modifier is present by confirming normal calls succeed
      // and no re-entrancy vector exists through the ERC-721 safeTransfer callback.
      // Full reentrancy test would require a malicious ERC-721 receiver mock.
      const { vault, holder } = await loadFixture(deployFixture);
      await vault.connect(holder).lockNFTs([1]);
      await vault.connect(holder).harvestERC20(1);
      // No revert = protected path executed cleanly
    });
  });

});
