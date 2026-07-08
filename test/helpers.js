// test/helpers.js
// Shared fixtures, constants and utilities for all EWB test suites

const { ethers } = require("hardhat");

// ── CONSTANTS ─────────────────────────────────────────────────
const TIER = { EPIC: 0, SUPER_RARE: 1, RARE: 2, STANDARD: 3 };

const TIER_FLOORS = {
  EPIC:       ethers.parseEther("315"),
  SUPER_RARE: ethers.parseEther("22"),
  RARE:       ethers.parseEther("10"),
  STANDARD:   ethers.parseEther("1"),
};

const LTV = { EPIC: 3000, SUPER_RARE: 2500, RARE: 1500, STANDARD: 800 };
const PRECISION = 10_000n;
const ETH_USD_PRICE = ethers.parseUnits("2700", 8); // $2,700 with 8 dec
const INTEREST_RATE_BPS = 500n; // 5% pa
const SECONDS_PER_YEAR = 365n * 24n * 3600n;
const USDC_DECIMALS = 6;
const KYC_MAX_AGE = 24 * 3600; // 24 hours
const MAX_PAUSE_DURATION = 72 * 3600; // 72 hours

// ── MOCK ERC20 (USDC) ──────────────────────────────────────────
async function deployMockUSDC(deployer) {
  const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
  return MockERC20.deploy("USD Coin", "USDC", 6);
}

// ── MOCK ERC721 (EWB NFT) ──────────────────────────────────────
async function deployMockERC721(deployer) {
  const MockERC721 = await ethers.getContractFactory("MockERC721", deployer);
  return MockERC721.deploy("Exposed Walls (EWB)", "EWB");
}

// ── MOCK ORACLE ────────────────────────────────────────────────
async function deployMockOracle(deployer, floorETH, ethUSD) {
  const MockOracle = await ethers.getContractFactory("MockOracle", deployer);
  const oracle = await MockOracle.deploy(
    floorETH ?? ethers.parseEther("4.29"),
    ethUSD   ?? ETH_USD_PRICE
  );
  return oracle;
}

async function impersonateAccount(address, balance = "0x8AC7230489E80000") {
  await ethers.provider.send("hardhat_impersonateAccount", [address]);
  await ethers.provider.send("hardhat_setBalance", [address, balance]);
  return await ethers.getSigner(address);
}

// ── SIGN KYC ATTESTATION ───────────────────────────────────────
async function signKYCAttestation(signer, borrower, kycId, dataTimestamp, nonce) {
  const dataHash = ethers.solidityPackedKeccak256(
    ["string", "address", "uint256", "string", "bytes32"],
    ["EWB_HARDSCAN_KYC_V1", borrower, dataTimestamp, kycId, nonce]
  );
  return signer.signMessage(ethers.getBytes(dataHash));
}

// ── SIGN HEDGE ATTESTATION ─────────────────────────────────────
// The vault (VaultHedge.submitHedgeAttestation) hashes the position fields
// with HedgeAttestationLib.buildHash(...) and then binds the result to a
// per-submission nonce:  dataHash = keccak256(buildHash || nonce).
// The attestor signs that combined dataHash as an eth-signed message.
async function signHedgeAttestation(
  signer, notional, leverage, marginUSD, fundingRateBps, timestamp, accountId, nonce
) {
  const inner = ethers.solidityPackedKeccak256(
    ["string","uint256","uint256","uint256","uint256","uint256","string"],
    ["EWB_HEDGE_ATTESTATION_V1",
     notional, leverage, marginUSD, fundingRateBps, timestamp, accountId]
  );
  // Bind to the nonce exactly as the contract does before recovery.
  const dataHash = ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32"],
    [inner, nonce]
  );
  return signer.signMessage(ethers.getBytes(dataHash));
}

// ── MAINNET ADDRESSES HARD-CODED IN THE VAULT ──────────────────
// EWBDeltaNeutralVault (VaultStorage) talks to these fixed mainnet
// addresses. On the in-memory Hardhat network there is no code there,
// so we etch mock bytecode at each address before exercising the
// deploy / harvest / withdraw paths.
const DN_ADDR = {
  AAVE:   "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
  STETH:  "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
  WSTETH: "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
  CURVE:  "0xDC24316b9AE028F1497c275EB9192a3Ea0f67022",
};

// Deploy `factoryName`, copy its runtime bytecode to `targetAddr`, and
// return a contract handle bound to that address. Storage at the target
// starts empty (constructor initialisers do NOT run), so callers must
// seed any required state (e.g. Aave health factor) explicitly.
async function etchMock(targetAddr, factoryName, ...ctorArgs) {
  const F    = await ethers.getContractFactory(factoryName);
  const inst = await F.deploy(...ctorArgs);
  await inst.waitForDeployment();
  const code = await ethers.provider.getCode(await inst.getAddress());
  await ethers.provider.send("hardhat_setCode", [targetAddr, code]);
  return ethers.getContractAt(factoryName, targetAddr);
}

// Etch the full external dependency set for EWBDeltaNeutralVault and
// return the (address-bound) Aave mock so tests can tune the health
// factor. Aave HF defaults to 2.0x — above every vault threshold.
async function etchDeltaNeutralMocks(healthFactor = ethers.parseEther("2")) {
  await etchMock(DN_ADDR.STETH,  "MockLido");
  await etchMock(DN_ADDR.WSTETH, "MockWstETH");
  await etchMock(DN_ADDR.CURVE,  "MockCurvePool");
  const aave = await etchMock(DN_ADDR.AAVE, "MockAaveV3Pool");
  await (await aave.setHealthFactor(healthFactor)).wait();
  return aave;
}

// ── TIME HELPERS ──────────────────────────────────────────────
async function increaseTime(seconds) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine");
}

async function getBlockTimestamp() {
  const block = await ethers.provider.getBlock("latest");
  return block.timestamp;
}

// ── CALC HELPERS ──────────────────────────────────────────────
function calcInterest(principal, elapsedSeconds) {
  return principal * INTEREST_RATE_BPS * BigInt(elapsedSeconds)
    / PRECISION / SECONDS_PER_YEAR;
}

function calcMaxLoan(faceValueUSD, tier) {
  return faceValueUSD * BigInt(LTV[Object.keys(TIER).find(k => TIER[k] === tier)]) / PRECISION;
}

module.exports = {
  TIER, TIER_FLOORS, LTV, PRECISION, ETH_USD_PRICE,
  INTEREST_RATE_BPS, SECONDS_PER_YEAR, USDC_DECIMALS,
  KYC_MAX_AGE, MAX_PAUSE_DURATION,
  deployMockUSDC, deployMockERC721, deployMockOracle,
  impersonateAccount,
  signKYCAttestation, signHedgeAttestation,
  increaseTime, getBlockTimestamp,
  calcInterest, calcMaxLoan,
  DN_ADDR, etchMock, etchDeltaNeutralMocks,
};
