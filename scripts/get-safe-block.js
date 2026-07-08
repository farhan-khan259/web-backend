#!/usr/bin/env node
// scripts/get-safe-block.js
// Determines a safe, confirmed block number for fork testing
// Run: node scripts/get-safe-block.js

const { ethers } = require("ethers");
require("dotenv").config();

const RPC_URL = process.env.MAINNET_RPC_URL || "https://eth.llamarpc.com";
const CONFIRMATION_DEPTH = 256; // Ethereum mainnet: ~12 block finality + 244 block buffer

async function main() {
  try {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    
    // Get the latest block
    const latestBlock = await provider.getBlockNumber();
    console.log("✓ Latest block:", latestBlock);
    
    // Calculate a safe confirmed block (256 blocks behind)
    const safeBlock = latestBlock - CONFIRMATION_DEPTH;
    console.log("✓ Safe confirmed block (256 back):", safeBlock);
    
    // Verify the safe block exists and get its timestamp
    const block = await provider.getBlock(safeBlock);
    const now = Math.floor(Date.now() / 1000);
    const age = now - block.timestamp;
    console.log("✓ Safe block timestamp:", new Date(block.timestamp * 1000).toISOString());
    console.log("✓ Block age:", Math.floor(age / 60), "minutes old");
    console.log("✓ Block is finalized:", age > 0 ? "YES" : "NO");
    
    console.log("\n📋 UPDATE hardhat.config.js with:");
    console.log(`  blockNumber: ${safeBlock},`);
    
    process.exit(0);
  } catch (error) {
    console.error("✗ Error fetching block:", error.message);
    process.exit(1);
  }
}

main();
