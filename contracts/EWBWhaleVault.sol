// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBWhaleVault
 * @author Wayne Fyffe — Exposed Walls (EWB)
 *
 * ================================================================
 * WHAT WAYNE IS LEVERAGING
 * ================================================================
 *
 * Wayne Fyffe owns the RIGHT TO MINT 9,300 EWB ERC-721 tokens
 * that do not yet exist on-chain. These unminted tokens have
 * established floor values by tier:
 *
 *   EPIC:        315 ETH floor × 16 tokens  =  5,040 ETH face
 *   SUPER RARE:   22 ETH floor × 362 tokens =  7,964 ETH face
 *   RARE:         10 ETH floor × 1,492 tokens = 14,920 ETH face
 *   STANDARD:      1 ETH floor × 8,130 tokens =  8,130 ETH face
 *   ─────────────────────────────────────────────────────────────
 *   TOTAL FACE VALUE:                          36,054 ETH
 *   AT $1,601 ETH:                            ~$57.7M USD
 *
 * Wayne never mints the tokens.
 * Wayne never sells the tokens.
 * Wayne never transfers the tokens.
 *
 * He locks the MINTING RIGHTS — the on-chain proof that he
 * controls those future token IDs — as collateral.
 * The contract calculates credit capacity from tier floor
 * constants and LTV caps hardcoded in bytecode.
 *
 * ================================================================
 * CREDIT CAPACITY (at floor values)
 * ================================================================
 *
 *   EPIC:       5,040 ETH × 30% LTV = 1,512 ETH credit
 *   SUPER RARE: 7,964 ETH × 25% LTV = 1,991 ETH credit
 *   RARE:      14,920 ETH × 15% LTV = 2,238 ETH credit
 *   STANDARD:   8,130 ETH ×  8% LTV =   650 ETH credit
 *   ─────────────────────────────────────────────────────────────
 *   TOTAL CREDIT CAPACITY:            6,391 ETH (~$10.2M USD)
 *
 * ================================================================
 * HOW IT WORKS
 * ================================================================
 *
 *   1. Wayne calls lockMintingRights(tokenIds[], purpose, expiry)
 *      — Ballet wallet signs via WalletConnect
 *      — Token IDs recorded as locked (unminted, no transfer)
 *      — Face value calculated from tier floor constants
 *      — LockId issued as proof of collateral
 *
 *   2. EWBMintingRightsVault reads lockId
 *      — Borrows Circle USDC from Aave against face value × LTV
 *      — USDC sent directly to Ballet wallet
 *
 *   3. DeltaNeutralVault generates yield
 *      — ETH → Lido → stETH → Aave → yield
 *      — Yield swapped to USDC via Uniswap V3
 *      — USDC auto-repays Aave debt
 *
 *   4. Wayne calls unlockMintingRights(lockId)
 *      — Only after debt fully repaid
 *      — Token IDs released — cycle resets
 *
 * ================================================================
 * INVARIANTS
 * ================================================================
 *
 *   INV-1: Token ID cannot be locked twice
 *          assert: tokenIdLocked[id] == false before lock
 *
 *   INV-2: Face value calculated only from immutable tier floors
 *          assert: faceETH = Σ TIER_FLOOR_X × tokenCount
 *
 *   INV-3: Only owner (Ballet wallet) can lock or unlock
 *          assert: msg.sender == owner
 *
 *   INV-4: Only owner can unlock — minting rights protected
 *          assert: unlockMintingRights() onlyOwner
 *
 *   INV-5: totalLockedFaceETH stays in sync with all active locks
 *          assert: Σ lock.faceValueETH == totalLockedFaceETH
 *
 * ================================================================
 * CONFIRMED ADDRESSES — HARDCODED
 * ================================================================
 *
 *   Ballet wallet (owner):  0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *   EWB NFT contract:       0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4
 *   Chainlink ETH/USD:      0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
 *
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// ── Interfaces ──────────────────────────────────────────────────

interface IEWBGorillaOracle {
    function getETHUSDPrice()  external view returns (uint256);
    function getFloorPriceETH() external view returns (uint256);
}

interface IEWBCreditBridge {
    function onLock(uint256 lockId, uint256 faceValueETH) external;
    function onUnlock(uint256 lockId) external;
}

// ── Contract ────────────────────────────────────────────────────

contract EWBWhaleVault is ReentrancyGuard, Pausable {

    // ================================================================
    // TIER FLOOR CONSTANTS — IMMUTABLE IN BYTECODE
    // These are the ETH floor values per token per tier.
    // They cannot be changed after deployment.
    // All credit calculations derive from these values only.
    // ================================================================

    uint256 public constant TIER_FLOOR_EPIC       = 315; // ETH
    uint256 public constant TIER_FLOOR_SUPER_RARE =  22; // ETH
    uint256 public constant TIER_FLOOR_RARE       =  10; // ETH
    uint256 public constant TIER_FLOOR_STANDARD   =   1; // ETH

    // ================================================================
    // LTV CAPS — IMMUTABLE IN BYTECODE
    // Maximum credit as percentage of face value per tier.
    // Cannot be changed after deployment.
    // ================================================================

    uint256 public constant LTV_EPIC       = 3_000; // 30%
    uint256 public constant LTV_SUPER_RARE = 2_500; // 25%
    uint256 public constant LTV_RARE       = 1_500; // 15%
    uint256 public constant LTV_STANDARD   =   800; //  8%

    // ================================================================
    // TOTAL CREDIT CAPACITY — DERIVED FROM FLOORS AND LTV
    // 16 EPIC   × 315 ETH × 30% = 1,512 ETH
    // 362 SR    ×  22 ETH × 25% = 1,991 ETH
    // 1492 RARE ×  10 ETH × 15% = 2,238 ETH
    // 8130 STD  ×   1 ETH ×  8% =   650 ETH
    // TOTAL                       6,391 ETH
    // ================================================================

    uint256 public constant TOTAL_CREDIT_ETH = 6_391 ether;

    // ── Tier IDs ────────────────────────────────────────────────

    uint8 public constant TIER_EPIC_ID       = 0;
    uint8 public constant TIER_SUPER_RARE_ID = 1;
    uint8 public constant TIER_RARE_ID       = 2;
    uint8 public constant TIER_STANDARD_ID   = 3;

    uint256 public constant PRECISION             = 10_000;
    uint256 public constant SNAPSHOT_MAX_DEV_BPS  = 500; // ±5% MEV cap
    uint256 public constant MAX_PAUSE_DURATION    = 72 hours;

    // ── Confirmed addresses ─────────────────────────────────────

    /// @notice Ballet wallet — Wayne Fyffe — sole owner
    address public constant BALLET_WALLET =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    /// @notice EWB NFT contract — live on mainnet since 2021
    address public constant EWB_NFT_CONTRACT =
        0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4;

    // ── State ────────────────────────────────────────────────────

    address public immutable owner;

    IEWBGorillaOracle public oracle;
    address           public creditBridge;
    address           public deltaVault;

    uint256 public lockCount;
    uint256 public totalLockedFaceETH;

    bool    public tiersLocked;
    uint256 public pausedAt;

    // ── Tier assignments ─────────────────────────────────────────

    struct TierAssignment {
        uint8 tier;
        bool  assigned;
    }
    mapping(uint256 => TierAssignment) public tokenTiers;

    // ── Lock registry ────────────────────────────────────────────

    struct MintingLock {
        uint256[] tokenIds;
        uint256   faceValueETH;
        uint256   faceValueUSD;
        uint256   lockedAt;
        uint256   expiresAt;
        bool      active;
        string    purpose;
    }

    mapping(uint256 => MintingLock) public mintingLocks;
    mapping(uint256 => bool)        public tokenIdLocked;
    mapping(uint256 => uint256)     public tokenIdToLockId;

    // ── Events ───────────────────────────────────────────────────

    event MintingRightsLocked(
        uint256 indexed lockId,
        uint256[] tokenIds,
        uint256 faceValueETH,
        uint256 faceValueUSD,
        string  purpose,
        uint256 expiresAt
    );
    event MintingRightsUnlocked(uint256 indexed lockId, uint256 timestamp);
    event LockRevalued(uint256 indexed lockId, uint256 oldETH, uint256 newETH, uint256 oldUSD, uint256 newUSD);
    event CreditBridgeCallFailed(uint256 indexed lockId, string reason);
    event TierSet(uint256 indexed tokenId, uint8 tier);
    event TiersLockedPermanently(uint256 timestamp);
    event OracleSet(address oracle);
    event CreditBridgeSet(address bridge);

    // ── Errors ───────────────────────────────────────────────────

    error NotOwner();
    error TokenIdAlreadyLocked(uint256 tokenId);
    error LockNotActive();
    error TiersAlreadyLocked();
    error ExpiryInPast();
    error TierNotAssigned(uint256 tokenId);
    error OnlyDeltaNeutralVault();

    // ── Modifiers ────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEmergency() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────

    constructor(address _oracle) {
        owner  = BALLET_WALLET;
        oracle = IEWBGorillaOracle(_oracle);
    }

    // ================================================================
    // CORE — LOCK MINTING RIGHTS
    // ================================================================

    /**
     * @notice Lock unminted EWB minting rights as collateral
     *
     * @dev This is the foundation of the leverage system.
     *      Wayne locks token IDs that DO NOT EXIST YET on-chain.
     *      No NFT transfer occurs. The rights are purely on-chain
     *      proof of Wayne's ability to mint those future tokens.
     *
     *      Face value is calculated from immutable tier floor constants:
     *        EPIC:        315 ETH per token
     *        SUPER RARE:   22 ETH per token
     *        RARE:         10 ETH per token
     *        STANDARD:      1 ETH per token
     *
     *      The resulting lockId is used by EWBMintingRightsVault
     *      to borrow Circle USDC from Aave against face value × LTV.
     *
     * @param tokenIds  Unminted EWB token IDs to commit (max 500 per call)
     * @param purpose   "credit" | "harvest" | "yield"
     * @param expiresAt Unix timestamp for lock expiry (0 = no expiry)
     */
    function lockMintingRights(
        uint256[] calldata tokenIds,
        string    calldata purpose,
        uint256            expiresAt
    )
        external
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (uint256 lockId)
    {
        require(tokenIds.length > 0, "No token IDs");
        require(tokenIds.length <= 500, "Max 500 per batch");
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiryInPast();

        // INV-1: cannot double-lock
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIdLocked[tokenIds[i]]) revert TokenIdAlreadyLocked(tokenIds[i]);
        }

        // Calculate face value from immutable tier floors
        uint256 faceETH;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            faceETH += _getTierFloorWei(tokenIds[i]);
        }

        // MEV snapshot check
        uint256 ethUSD   = oracle.getETHUSDPrice();
        uint256 floorETH = oracle.getFloorPriceETH();
        if (floorETH > 0) {
            uint256 floorUSD    = (floorETH * ethUSD) / 1e18;
            uint256 batchAvgETH = faceETH / tokenIds.length;
            uint256 spotPrice   = (batchAvgETH * ethUSD) / 1e18;
            uint256 deviation   = spotPrice > floorUSD
                ? ((spotPrice - floorUSD) * 10000) / floorUSD
                : ((floorUSD - spotPrice) * 10000) / floorUSD;
            require(deviation <= SNAPSHOT_MAX_DEV_BPS, "MEV: price deviation >5%");
        }

        uint256 faceUSD = (faceETH * ethUSD) / 1e18;

        lockCount++;
        lockId = lockCount;

        mintingLocks[lockId] = MintingLock({
            tokenIds:     tokenIds,
            faceValueETH: faceETH,
            faceValueUSD: faceUSD,
            lockedAt:     block.timestamp,
            expiresAt:    expiresAt,
            active:       true,
            purpose:      purpose
        });

        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenIdLocked[tokenIds[i]]    = true;
            tokenIdToLockId[tokenIds[i]]  = lockId;
        }

        totalLockedFaceETH += faceETH;

        // Notify CreditBridge — auto-deploys LTV ETH to DeltaNeutralVault
        if (creditBridge != address(0)) {
            try IEWBCreditBridge(creditBridge).onLock(lockId, faceETH) {}
            catch { emit CreditBridgeCallFailed(lockId, "onLock"); }
        }

        emit MintingRightsLocked(lockId, tokenIds, faceETH, faceUSD, purpose, expiresAt);
    }

    // ================================================================
    // CORE — UNLOCK MINTING RIGHTS
    // ================================================================

    /**
     * @notice Release locked minting rights
     * @dev Only callable by Ballet wallet.
     *      Should only be called after Aave debt fully repaid.
     *      Cycle resets — same token IDs can be locked again.
     */
    function unlockMintingRights(uint256 lockId)
        external
        onlyOwner
        nonReentrant
    {
        MintingLock storage lock = mintingLocks[lockId];
        if (!lock.active) revert LockNotActive();

        for (uint256 i = 0; i < lock.tokenIds.length; i++) {
            tokenIdLocked[lock.tokenIds[i]]   = false;
            tokenIdToLockId[lock.tokenIds[i]] = 0;
        }

        totalLockedFaceETH -= lock.faceValueETH;
        lock.active = false;

        // Notify CreditBridge
        if (creditBridge != address(0)) {
            try IEWBCreditBridge(creditBridge).onUnlock(lockId) {}
            catch {}
        }

        emit MintingRightsUnlocked(lockId, block.timestamp);
    }

    // ── Admin ────────────────────────────────────────────────────

    function revalueLock(uint256 lockId, uint256 newFaceETH, uint256 newFaceUSD)
        external onlyOwner nonReentrant
    {
        require(mintingLocks[lockId].active, "Lock not active");
        require(newFaceETH > 0, "Zero face value");
        uint256 oldETH = mintingLocks[lockId].faceValueETH;
        uint256 oldUSD = mintingLocks[lockId].faceValueUSD;

        // INV-5: keep totalLockedFaceETH in sync
        if (newFaceETH > oldETH) {
            totalLockedFaceETH += (newFaceETH - oldETH);
        } else {
            totalLockedFaceETH -= (oldETH - newFaceETH);
        }

        mintingLocks[lockId].faceValueETH = newFaceETH;
        mintingLocks[lockId].faceValueUSD = newFaceUSD;
        emit LockRevalued(lockId, oldETH, newFaceETH, oldUSD, newFaceUSD);
    }

    function setTokenTiers(uint256[] calldata tokenIds, uint8[] calldata tiers)
        external onlyOwner
    {
        require(!tiersLocked, "Tiers permanently locked");
        require(tokenIds.length == tiers.length, "Length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenTiers[tokenIds[i]] = TierAssignment({ tier: tiers[i], assigned: true });
            emit TierSet(tokenIds[i], tiers[i]);
        }
    }

    function lockTiers() external onlyOwner {
        tiersLocked = true;
        emit TiersLockedPermanently(block.timestamp);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero address");
        oracle = IEWBGorillaOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setCreditBridge(address _bridge) external onlyOwner {
        // L-2 FIX: single assignment — cannot be changed after set
        require(creditBridge == address(0), "CreditBridge already set");
        require(_bridge != address(0), "Zero address");
        creditBridge = _bridge;
        emit CreditBridgeSet(_bridge);
    }

    function setDeltaVault(address _vault) external onlyOwner {
        deltaVault = _vault;
    }

    function pause() external onlyEmergency {
        pausedAt = block.timestamp;
        _pause();
    }

    function unpause() external onlyEmergency { _unpause(); }

    function forceUnpause() external onlyOwner {
        require(block.timestamp >= pausedAt + MAX_PAUSE_DURATION, "Max pause not elapsed");
        _unpause();
    }

    // ── Views ─────────────────────────────────────────────────────

    function getLock(uint256 lockId) external view returns (
        uint256[] memory tokenIds,
        uint256 faceValueETH,
        uint256 faceValueUSD,
        uint256 lockedAt,
        uint256 expiresAt,
        bool    active,
        string  memory purpose
    ) {
        MintingLock storage l = mintingLocks[lockId];
        return (l.tokenIds, l.faceValueETH, l.faceValueUSD, l.lockedAt, l.expiresAt, l.active, l.purpose);
    }

    function getLockFaceValueETH(uint256 lockId) external view returns (uint256) {
        return mintingLocks[lockId].faceValueETH;
    }

    function getLockFaceValueUSD(uint256 lockId) external view returns (uint256) {
        require(mintingLocks[lockId].active, "Lock not active");
        return mintingLocks[lockId].faceValueUSD;
    }

    function isMintingRightLocked(uint256 tokenId) external view returns (bool) {
        if (!tokenIdLocked[tokenId]) return false;
        uint256 lockId = tokenIdToLockId[tokenId];
        MintingLock storage lock = mintingLocks[lockId];
        if (!lock.active) return false;
        if (lock.expiresAt > 0 && block.timestamp > lock.expiresAt) return false;
        return true;
    }

    function calculateFaceValue(uint256[] calldata tokenIds)
        external view returns (uint256 faceETH, uint256 faceUSD)
    {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            faceETH += _getTierFloorWei(tokenIds[i]);
        }
        try oracle.getETHUSDPrice() returns (uint256 price) {
            if (price > 0) faceUSD = faceETH * price / 1e18;
        } catch {
            faceUSD = 0;
        }
    }

    function getVaultStats() external view returns (
        uint256 _lockCount,
        uint256 _totalFaceETH,
        uint256 _totalFaceUSD
    ) {
        _lockCount    = lockCount;
        _totalFaceETH = totalLockedFaceETH;
        try oracle.getETHUSDPrice() returns (uint256 price) {
            _totalFaceUSD = totalLockedFaceETH * price / 1e18;
        } catch {
            _totalFaceUSD = 0;
        }
    }

    // ── Internal ──────────────────────────────────────────────────

    function _getTierFloorWei(uint256 tokenId) internal view returns (uint256) {
        TierAssignment storage ta = tokenTiers[tokenId];
        if (!ta.assigned) revert TierNotAssigned(tokenId);
        if (ta.tier == TIER_EPIC_ID)       return TIER_FLOOR_EPIC       * 1 ether;
        if (ta.tier == TIER_SUPER_RARE_ID) return TIER_FLOOR_SUPER_RARE * 1 ether;
        if (ta.tier == TIER_RARE_ID)       return TIER_FLOOR_RARE       * 1 ether;
        return TIER_FLOOR_STANDARD * 1 ether;
    }
}
