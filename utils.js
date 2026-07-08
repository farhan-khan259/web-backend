const { ethers } = require('ethers');
const { ADDRESSES } = require('./addresses');
const whaleVaultAbi = require('./abis/EWBWhaleVault.json');
const mintingVaultAbi = require('./abis/EWBMintingRightsVault.json');
const oracleAbi = require('./abis/EWBGorillaOracle.json');
const revenueRouterAbi = require('./abis/EWBRevenueRouter.json');
const deltaNeutralAbi = require('./abis/EWBDeltaNeutralVault.json');
const creditBridgeAbi = require('./abis/EWBCreditBridge.json');

const fallbackRpc = process.env.RPC_URL || 'https://eth-mainnet.public.blastapi.io';

function createProvider() {
  const rpcUrl = process.env.RPC_URL || fallbackRpc;
  return new ethers.JsonRpcProvider(rpcUrl);
}

function formatUnitsValue(value, decimals = 18) {
  if (!value) return '0';
  return Number(ethers.formatUnits(value, decimals)).toLocaleString(undefined, {
    maximumFractionDigits: decimals === 6 ? 2 : 4,
  });
}

function parseError(err) {
  return err?.reason || err?.message || String(err);
}

function normalizeForJson(value) {
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map(normalizeForJson);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, normalizeForJson(v)])
    );
  }
  return value;
}

async function fetchProtocolData() {
  const provider = createProvider();
  const whaleVault = new ethers.Contract(ADDRESSES.whaleVault, whaleVaultAbi.abi, provider);
  const mintingVault = new ethers.Contract(ADDRESSES.mintingVault, mintingVaultAbi.abi, provider);
  const oracle = new ethers.Contract(ADDRESSES.oracle, oracleAbi.abi, provider);
  const revenueRouter = new ethers.Contract(ADDRESSES.revenueRouter, revenueRouterAbi.abi, provider);
  const deltaNeutral = new ethers.Contract(ADDRESSES.deltaNeutralVault, deltaNeutralAbi.abi, provider);
  const creditBridge = new ethers.Contract(ADDRESSES.creditBridge, creditBridgeAbi.abi, provider);

  const [whaleStats, lockCount, totalLockedFaceEth, ethUsdPrice, floorEth, manualFloor, oraclePaused, mintingPaused, whalePaused, deltaPaused, bridgePaused, totalBorrowed, totalRepaid, creditCount, aavePosition, revenueReceived, revenueDistributed, deltaDeployed, deltaMax, bridgeDeployed, bridgeLtvBps] = await Promise.all([
    whaleVault.getVaultStats().catch(() => [0, 0, 0]),
    whaleVault.lockCount().catch(() => 0),
    whaleVault.totalLockedFaceETH().catch(() => 0),
    oracle.getETHUSDPrice().catch(() => 0),
    oracle.getFloorPriceETH().catch(() => 0),
    oracle.manualFloorETH?.().catch?.(() => 0) || Promise.resolve(0),
    oracle.paused?.().catch?.(() => false) || Promise.resolve(false),
    mintingVault.paused?.().catch?.(() => false) || Promise.resolve(false),
    whaleVault.paused?.().catch?.(() => false) || Promise.resolve(false),
    deltaNeutral.paused?.().catch?.(() => false) || Promise.resolve(false),
    creditBridge.paused?.().catch?.(() => false) || Promise.resolve(false),
    mintingVault.totalBorrowed().catch(() => 0),
    mintingVault.totalRepaid().catch(() => 0),
    mintingVault.creditCount().catch(() => 0),
    mintingVault.getAavePosition().catch(() => [0, 0, 0, 0]),
    revenueRouter.totalReceived?.(0).catch?.(() => 0) || Promise.resolve(0),
    revenueRouter.totalDistributed?.(0).catch?.(() => 0) || Promise.resolve(0),
    deltaNeutral.totalDeployed?.().catch?.(() => 0) || Promise.resolve(0),
    deltaNeutral.maxDeployment?.().catch?.(() => 0) || Promise.resolve(0),
    creditBridge.totalBridgeDeployed?.().catch?.(() => 0) || Promise.resolve(0),
    creditBridge.ltvBps?.().catch?.(() => 0) || Promise.resolve(0),
  ]);

  const totalValueLocked = Number(totalLockedFaceEth || 0) + Number(deltaDeployed || 0);
  const tvlUsd = totalValueLocked * (Number(ethUsdPrice || 0) / 1e18);
  const outstandingDebt = Number(totalBorrowed || 0) - Number(totalRepaid || 0);
  const revenue = Number(revenueReceived || 0) + Number(revenueDistributed || 0);

  return {
    contracts: {
      oracle: ADDRESSES.oracle,
      whaleVault: ADDRESSES.whaleVault,
      mintingVault: ADDRESSES.mintingVault,
      revenueRouter: ADDRESSES.revenueRouter,
      deltaNeutralVault: ADDRESSES.deltaNeutralVault,
      creditBridge: ADDRESSES.creditBridge,
      devPayment: ADDRESSES.devPayment,
      gasPaymaster: ADDRESSES.gasPaymaster,
      layer1: ADDRESSES.layer1,
      layer2: ADDRESSES.layer2,
      layer3: ADDRESSES.layer3,
      milestone: ADDRESSES.milestone,
      nftHarvest: ADDRESSES.nftHarvest,
      privHarvest: ADDRESSES.privHarvest,
      privPool: ADDRESSES.privPool,
      rwa: ADDRESSES.rwa,
      trademark: ADDRESSES.trademark,
      nft: ADDRESSES.nft,
    },
    whaleStats: {
      lockCount: Number(lockCount || 0),
      totalFaceEth: totalLockedFaceEth,
      totalFaceUsd: whaleStats?.[2] || 0,
    },
    oracle: {
      ethUsdPrice,
      floorEth,
      manualFloor,
      useManualFloor: Boolean(manualFloor && manualFloor > 0),
      staleness: Number(ethUsdPrice || 0) <= 0,
    },
    status: {
      whaleVault: whalePaused,
      mintingVault: mintingPaused,
      oracle: oraclePaused,
      revenueRouter: false,
      deltaNeutralVault: deltaPaused,
      creditBridge: bridgePaused,
    },
    mintingVault: {
      totalBorrowed,
      totalRepaid,
      creditCount: Number(creditCount || 0),
      aavePosition,
      outstandingDebt,
    },
    revenueRouter: {
      received: revenueReceived,
      distributed: revenueDistributed,
      revenue,
      estimates: {
        lpFees: 160823e6,
        stEth: 7340e6,
        dydx: 16776e6,
      },
    },
    deltaNeutral: {
      totalDeployed: deltaDeployed,
      maxDeployment: deltaMax,
      paused: deltaPaused,
    },
    creditBridge: {
      totalBridgeDeployed: bridgeDeployed,
      ltvBps: bridgeLtvBps,
      paused: bridgePaused,
    },
    stats: {
      tvlEth: totalValueLocked,
      tvlUsd,
      totalBorrowed: Number(totalBorrowed || 0),
      activeLoans: Number(creditCount || 0),
      totalNftLocks: Number(lockCount || 0),
      protocolRevenue: revenue,
    },
  };
}

module.exports = { fetchProtocolData, formatUnitsValue, parseError, normalizeForJson };
