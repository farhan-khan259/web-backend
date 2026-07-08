const ethers = require("ethers");

async function main() {
  // Load ABIs
  const whaleABI = [
    "function setTokenTiers(uint256[] memory tokenIds, uint8[] memory tiers) external",
    "function lockMintingRights(uint256[] memory tokenIds, uint256 faceValueETH, uint256 faceValueUSD, string memory memo, uint256 nonce) external returns (uint256 lockId)"
  ];
  const mintingABI = [
    "function borrowUSDC(uint256 lockId, uint256 amount) external"
  ];

  const whaleInterface = new ethers.Interface(whaleABI);
  const mintingInterface = new ethers.Interface(mintingABI);

  const tokenIds = [1];
  const tiers = [0];
  const faceValueETH = ethers.parseEther("315");
  const faceValueUSD = 567000000000; // 315 * 1800 * 1e6
  const memo = "borrow-250k-test";
  const nonce = 0;
  const borrowAmount = 250000000000; // 250k USDC

  console.log("===== SET TOKEN TIERS =====");
  const setTiersData = whaleInterface.encodeFunctionData("setTokenTiers", [tokenIds, tiers]);
  console.log("Contract: 0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529");
  console.log("Calldata:", setTiersData);

  console.log("\n===== LOCK MINTING RIGHTS =====");
  const lockData = whaleInterface.encodeFunctionData("lockMintingRights", [tokenIds, faceValueETH, faceValueUSD, memo, nonce]);
  console.log("Contract: 0x7048fDfA11f70B7f4cD08ba5e8F7F299DCb07529");
  console.log("Calldata:", lockData);
  console.log("Params: tokenIds=[1], faceValueETH=315 ether, faceValueUSD=567000000000, memo='borrow-250k-test', nonce=0");
  console.log("After executing this, note the lockId from the transaction receipt (MintingRightsLocked event).");

  console.log("\n===== BORROW USDC =====");
  console.log("Once you have the lockId, use it to call borrowUSDC:");
  const borrowData = mintingInterface.encodeFunctionData("borrowUSDC", ["<LOCK_ID>", borrowAmount]);
  console.log("Contract: 0x2E4C26B33Ae96823e1C37cDbCB28dF0169A2738D");
  console.log("Calldata with placeholder: ", borrowData);
  console.log("Replace <LOCK_ID> with the actual lockId from the lockMintingRights event.");
  console.log("Amount: 250000000000 (250,000 USDC in 6 decimals).");
}

main().catch(console.error);
