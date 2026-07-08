// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBCreditBridge
 * @author Wayne Fyffe — Exposed Walls (EWB)
 *
 * ================================================================
 * WHAT THIS CONTRACT DOES
 * ================================================================
 *
 * The automated link between WhaleVault and DeltaNeutralVault.
 *
 * When Wayne locks minting rights in WhaleVault, this contract
 * automatically deploys ETH into DeltaNeutralVault to start
 * generating yield. No second signature needed.
 *
 * ================================================================
 * FULL AUTOMATED LOOP
 * ================================================================
 *
 *   STEP 1 — Wayne funds the bridge (one time)
 *   Ballet wallet calls fund() and sends ETH
 *   ETH sits in bridge ready to deploy
 *
 *   STEP 2 — Wayne locks minting rights (Ballet signs once)
 *   WhaleVault.lockMintingRights(tokenIds[], purpose, expiry)
 *       ↓ auto — WhaleVault calls this contract
 *   onLock(lockId, faceValueETH)
 *       ↓ auto
 *   ETH deployed to DeltaNeutralVault
 *       ↓ auto
 *   ETH → Lido → wstETH → Aave → yield accumulates
 *
 *   STEP 3 — Wayne borrows USDC (Ballet signs once)
 *   EWBMintingRightsVault.borrowUSDC(lockId, tokenIds[], amount)
 *       ↓ auto
 *   Aave releases Circle USDC
 *       ↓ auto
 *   USDC → Ballet wallet 0xc82A...D46cf instantly
 *
 *   STEP 4 — Yield auto-repays debt (no signature needed)
 *   DeltaNeutralVault.harvestToUSDC()
 *       ↓ auto
 *   stETH yield → Uniswap → USDC
 *       ↓ auto
 *   EWBMintingRightsVault.autoRepay() called
 *       ↓ auto
 *   Aave debt paid down
 *       ↓ auto
 *   Borrowing capacity restored
 *
 *   STEP 5 — Cycle resets
 *   Wayne calls borrowUSDC() again when ready
 *   Or unlockMintingRights() to close the cycle
 *
 * ================================================================
 * WHAT WAYNE SIGNS
 * ================================================================
 *
 *   fund()                   — one time — seeds the bridge with ETH
 *   lockMintingRights()      — once per cycle — triggers auto-deploy
 *   borrowUSDC()             — when he wants USDC
 *   unlockMintingRights()    — to close cycle
 *
 * ================================================================
 * WHAT IS FULLY AUTOMATIC (no signature)
 * ================================================================
 *
 *   onLock()                 — ETH deployed when lock triggers
 *   deployLongLeg()          — ETH → wstETH → Aave
 *   harvestToUSDC()          — yield → USDC
 *   autoRepay()              — yield pays Aave debt
 *   borrowing capacity restored automatically
 *
 * ================================================================
 * CONFIRMED ADDRESSES
 * ================================================================
 *
 *   Ballet wallet (owner):  0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *   All USDC goes to:       0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// ── Interfaces ──────────────────────────────────────────────────

interface IEWBWhaleVault {
    function getLockFaceValueETH(uint256 lockId) external view returns (uint256);
    function getLockFaceValueUSD(uint256 lockId) external view returns (uint256);
    function isMintingRightLocked(uint256 tokenId) external view returns (bool);
    function owner() external view returns (address);
}

interface IEWBDeltaNeutralVault {
    function deployLongLeg() external payable;
    function totalDeployed() external view returns (uint256);
    function maxDeployment() external view returns (uint256);
    function emergencyExit() external;
}

// ── Contract ────────────────────────────────────────────────────

contract EWBCreditBridge is ReentrancyGuard, Pausable {

    // ── Constants ───────────────────────────────────────────────

    uint256 public constant PRECISION       = 10_000;
    uint256 public constant MAX_DEPLOYMENT_ETH = 6_391 ether;

    /// @notice Ballet wallet — Wayne Fyffe — sole owner
    address public constant BALLET_WALLET =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // ── State ────────────────────────────────────────────────────

    address public immutable owner;
    address public immutable whaleVault;
    address public immutable deltaVault;

    /// @notice LTV basis points applied to face value ETH for deployment
    /// Default: 3000 = 30%
    uint256 public ltvBps = 3_000;

    /// @notice ETH deployed per lockId
    mapping(uint256 => uint256) public deployedPerLock;

    /// @notice Total ETH currently deployed via this bridge
    uint256 public totalBridgeDeployed;

    // ── Events ───────────────────────────────────────────────────

    event BridgeFunded(uint256 amount);
    event LockDeployed(
        uint256 indexed lockId,
        uint256 faceValueETH,
        uint256 ltvETH,
        uint256 deployedETH
    );
    event LockWithdrawn(uint256 indexed lockId, uint256 withdrawnETH);
    event PartialDeploy(uint256 indexed lockId, uint256 ltvETH, uint256 actualDeployed);
    event EmergencyExit(uint256 amount);

    // ── Modifiers ────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyWhaleVault() {
        require(msg.sender == whaleVault, "Not WhaleVault");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────

    constructor(
        address _whaleVault,
        address _deltaVault
    ) {
        require(_whaleVault != address(0), "Zero whaleVault");
        require(_deltaVault != address(0), "Zero deltaVault");

        owner      = BALLET_WALLET;
        whaleVault = _whaleVault;
        deltaVault = _deltaVault;
    }

    // ── Funding ──────────────────────────────────────────────────

    /**
     * @notice Fund the bridge with ETH ready to deploy
     * @dev Wayne sends ETH here once. Bridge holds it until lock triggers.
     *      When lockMintingRights() is called, this ETH automatically
     *      deploys to DeltaNeutralVault → Lido → wstETH → Aave → yield.
     */
    function fund() external payable onlyOwner {
        require(msg.value > 0, "Zero ETH");
        emit BridgeFunded(msg.value);
    }

    receive() external payable {
        emit BridgeFunded(msg.value);
    }

    // ── Core: Lock triggers automatic deployment ─────────────────

    /**
     * @notice Called automatically by WhaleVault when minting rights locked
     * @dev Wayne never calls this directly. It is triggered by lockMintingRights().
     *      Deploys LTV-equivalent ETH into DeltaNeutralVault automatically.
     *      ETH → Lido → wstETH → Aave → yield → auto-repays USDC debt
     *
     * @param lockId       The lock ID from WhaleVault
     * @param faceValueETH Face value in ETH (18 dec)
     */
    function onLock(uint256 lockId, uint256 faceValueETH)
        external
        onlyWhaleVault
        nonReentrant
        whenNotPaused
    {
        require(faceValueETH > 0, "Zero face value");
        require(deployedPerLock[lockId] == 0, "Lock already deployed");

        // Calculate ETH to deploy = face value × LTV
        uint256 ltvETH = faceValueETH * ltvBps / PRECISION;
        require(ltvETH > 0, "LTV too small");

        // Cap to available bridge balance and vault capacity
        IEWBDeltaNeutralVault dv = IEWBDeltaNeutralVault(deltaVault);
        uint256 remainingCap  = dv.maxDeployment() - dv.totalDeployed();
        uint256 currentBridgeBalance = address(this).balance;

        uint256 toDeploy = ltvETH;
        if (toDeploy > currentBridgeBalance)  toDeploy = currentBridgeBalance;
        if (toDeploy > remainingCap)   toDeploy = remainingCap;

        require(toDeploy > 0, unicode"Nothing to deploy — fund the bridge first");

        if (toDeploy < ltvETH) {
            emit PartialDeploy(lockId, ltvETH, toDeploy);
        }

        // CEI: record state before external call
        deployedPerLock[lockId]  = toDeploy;
        totalBridgeDeployed     += toDeploy;

        // Deploy ETH → DeltaNeutralVault → Lido → wstETH → Aave
        dv.deployLongLeg{value: toDeploy}();

        emit LockDeployed(lockId, faceValueETH, ltvETH, toDeploy);
    }

    /**
     * @notice Called automatically by WhaleVault when minting rights unlocked
     * @dev Records that ETH deployment for this lock is complete.
     *      ETH remains in Aave earning yield until harvestToUSDC() is called.
     *
     * @param lockId The lock ID being released
     */
    function onUnlock(uint256 lockId)
        external
        onlyWhaleVault
        nonReentrant
    {
        uint256 deployed = deployedPerLock[lockId];
        if (deployed == 0) return;

        deployedPerLock[lockId]  = 0;
        totalBridgeDeployed     -= deployed;

        emit LockWithdrawn(lockId, deployed);
    }

    // ── Admin ────────────────────────────────────────────────────

    function setLtvBps(uint256 _ltvBps) external onlyOwner {
        require(_ltvBps <= 5_000, "Max 50% LTV");
        ltvBps = _ltvBps;
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");
        (bool ok,) = payable(BALLET_WALLET).call{value: balance}("");
        require(ok, "Transfer failed");
        emit EmergencyExit(balance);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Views ─────────────────────────────────────────────────────

    function bridgeBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function deployedForLock(uint256 lockId) external view returns (uint256) {
        return deployedPerLock[lockId];
    }

    function vaultStats() external view returns (
        uint256 _balance,
        uint256 _totalDeployed,
        uint256 _ltvBps
    ) {
        _balance       = address(this).balance;
        _totalDeployed = totalBridgeDeployed;
        _ltvBps        = ltvBps;
    }
}
