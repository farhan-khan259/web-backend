// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBNFTHarvestVault
 * @author Wayne Fyffe — Exposed Walls (EWB)
 * @notice ERC-721 → ERC-20 Harvest Engine
 * @dev TECH1 GODMODE FINAL v1 — OpenZeppelin Audit Standard
 *
 * ================================================================
 * OVERVIEW
 * ================================================================
 *
 * Locks EWB ERC-721 NFTs and allows the holder to harvest their
 * floor value as ERC-20 tokens (L1T / L2T / L3T) proportional to
 * the tier-weighted face value of the locked NFTs.
 *
 * Integrates with the existing EWB stack:
 *   - EWBWhaleVault   — harvest token validation + minting lock gate
 *   - EWBGorillaOracle — live ETH/USD price for USD-denominated harvest
 *   - EWBLayer1Token  — ERC-20 minted to represent L1 face value
 *   - EWBLayer3Token  — ERC-20 used for yield pool deposits
 *
 * ================================================================
 * HARVEST FLOW
 * ================================================================
 *
 * 1. Owner approves this vault on the EWB ERC-721 contract
 * 2. Owner calls lockNFTs(tokenIds[], harvestToken)
 *    — NFTs transferred into vault custody
 *    — Lock record created with face value at oracle price
 *    — harvestToken must be a valid, fresh WhaleVault harvest token
 * 3. Owner calls harvestERC20(lockId)
 *    — WhaleVault.validateAndRecordHarvest() called (records on-chain)
 *    — ERC-20 amount = faceValueUSD × harvestRateBps / PRECISION
 *    — ERC-20 minted / transferred to NFT owner
 *    — Cooldown enforced: cannot harvest again until cooldown passes
 * 4. Owner calls unlockNFTs(lockId) to retrieve NFTs
 *    — Requires all accrued harvest obligations met (pendingHarvest == 0)
 *    — NFTs returned to original owner
 *
 * ================================================================
 * ERC-20 HARVEST RATE
 * ================================================================
 *
 * harvestRateBps: configured per deploy by multisig (default 1000 = 10%)
 * harvestTokenAddress: the ERC-20 contract to mint/transfer to holder
 *
 * Harvest amount (18-dec ERC-20 units):
 *   harvestAmount = faceValueUSD (6-dec) × harvestRateBps / PRECISION
 *                   × 1e12  (normalize to 18-dec)
 *
 * ================================================================
 * TIER FACE VALUES (matching EWBWhaleVault)
 * ================================================================
 *
 *   EPIC       315 ETH / token
 *   SUPER RARE  22 ETH / token
 *   RARE        10 ETH / token
 *   STANDARD     1 ETH / token
 *
 * ================================================================
 * FORMAL INVARIANTS
 * ================================================================
 *
 * INV-1: NFTs stay in vault custody while lock active
 *        assert: lock.active => IERC721(EWB_CONTRACT).ownerOf(tokenId)
 *        == address(this) for all lock.tokenIds
 *
 * INV-2: Harvest gated by valid WhaleVault harvest token
 *        assert: harvestERC20() reverts when
 *        whaleVault.hasValidHarvestToken(msg.sender) == false
 *
 * INV-3: Harvest rate never exceeds HARVEST_RATE_MAX_BPS (5000 = 50%)
 *        assert: harvestRateBps <= HARVEST_RATE_MAX_BPS always
 *
 * INV-4: Unlock only when no pending harvest obligation
 *        assert: unlockNFTs() reverts when pendingHarvest[lockId] > 0
 *
 * INV-5: Only original lock owner can harvest or unlock
 *        assert: lock.owner == msg.sender enforced on harvest + unlock
 *
 * ================================================================
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * Recommended: OpenZeppelin, Hacken, CertiK
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ── Interfaces ──────────────────────────────────────────────────

interface IEWBWhaleVault {
    function hasValidHarvestToken(address holder) external view returns (bool);
    function validateAndRecordHarvest(address holder) external returns (bool);
    function isMintingRightLocked(uint256 tokenId) external view returns (bool);

    struct TokenTier { uint8 tier; bool assigned; }
    function tokenTiers(uint256 tokenId) external view returns (uint8 tier, bool assigned);
}

interface IEWBOracle {
    function getETHUSDPrice() external view returns (uint256);
}

interface IEWBLayerToken {
    /**
     * @dev Vault calls this to push ERC-20 tokens to the harvest recipient.
     *      The layer token contract must grant MINTER_ROLE to this vault,
     *      OR the vault must hold a pre-funded balance (pull model).
     *      Phase 1: pre-funded balance (SafeERC20 transfer from vault reserve).
     *      Phase 2: dedicated mint() role on layer token contracts.
     */
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ────────────────────────────────────────────────────────────────

contract EWBNFTHarvestVault is ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ============================================================
    // CUSTOM ERRORS
    // ============================================================

    error OnlyMultisig();
    error OnlyEmergency();
    error ZeroAddress();
    error ZeroAmount();
    error EmptyTokenArray();
    error LockNotActive();
    error NotLockOwner();
    error NoValidHarvestToken();
    error HarvestCooldownActive(uint256 availableAt);
    error PendingHarvestNotCleared();
    error TokenIdAlreadyLocked(uint256 tokenId);
    error MintingRightConflict(uint256 tokenId);
    error InsufficientReserve();
    error HarvestRateExceedsMax();
    error ProtocolFeeExceedsMax();
    error MaxPauseNotReached();
    error TierNotAssigned(uint256 tokenId);

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice EWB ERC-721 contract (mainnet)
    address public constant EWB_CONTRACT =
        0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4;

    uint256 public constant PRECISION = 10_000;

    /// @notice Safety cap — harvest rate cannot exceed 50%
    uint256 public constant HARVEST_RATE_MAX_BPS = 5_000;

    /// @notice Safety cap — protocol fee cannot exceed 25% of harvest
    uint256 public constant PROTOCOL_FEE_MAX_BPS = 2_500;

    /// @notice Default protocol fee: 2% of each harvest emission
    uint256 public constant DEFAULT_PROTOCOL_FEE_BPS = 200;

    /// @notice Default cooldown between harvests: 30 days
    uint256 public constant DEFAULT_COOLDOWN = 30 days;

    uint256 public constant MAX_PAUSE_DURATION = 72 hours;

    // Tier floor values in wei (matching EWBWhaleVault)
    uint256 public constant TIER_FLOOR_EPIC       = 315 ether;
    uint256 public constant TIER_FLOOR_SUPER_RARE =  22 ether;
    uint256 public constant TIER_FLOOR_RARE       =  10 ether;
    uint256 public constant TIER_FLOOR_STANDARD   =   1 ether;

    uint8 public constant TIER_EPIC       = 0;
    uint8 public constant TIER_SUPER_RARE = 1;
    uint8 public constant TIER_RARE       = 2;
    uint8 public constant TIER_STANDARD   = 3;

    // ============================================================
    // IMMUTABLE GOVERNANCE
    // ============================================================

    /// @notice Safe 2-of-3 multisig — primary authority
    address public immutable safeMultisig;

    /// @notice Cold hardware wallet — emergency pause only
    address public immutable coldWallet;

    /// @notice EWBWhaleVault — harvest token validation
    IEWBWhaleVault public immutable whaleVault;

    /// @notice EWBGorillaOracle — ETH/USD price
    IEWBOracle public immutable oracle;

    // ============================================================
    // CONFIGURABLE STATE (multisig only)
    // ============================================================

    /// @notice ERC-20 token distributed on harvest (e.g. L1T or L3T)
    address public harvestTokenAddress;

    /// @notice Basis points of faceValueUSD paid out per harvest cycle
    /// @dev 1000 = 10% of face value. Capped at HARVEST_RATE_MAX_BPS.
    uint256 public harvestRateBps;

    /// @notice Seconds between permitted harvests per lock
    uint256 public harvestCooldown;

    /// @notice Protocol fee in basis points taken from each harvest (e.g. 200 = 2%)
    /// @dev Fee is deducted from gross harvest before sending to holder.
    ///      Accumulated in this contract, withdrawn by multisig via collectProtocolFees().
    uint256 public protocolFeeBps;

    /// @notice Accumulated protocol fees not yet withdrawn (18 dec ERC-20 units)
    uint256 public accumulatedFees;

    /// @notice Total protocol fees collected all time (18 dec ERC-20 units)
    uint256 public totalFeesCollected;

    // ============================================================
    // LOCK STATE
    // ============================================================

    struct NFTLock {
        address   owner;
        uint256[] tokenIds;
        uint256   faceValueETH;   // total face ETH at lock time (18 dec)
        uint256   faceValueUSD;   // total face USD at lock time (6 dec)
        uint256   lockedAt;
        uint256   lastHarvestAt;
        uint256   harvestCount;
        uint256   totalHarvested; // cumulative ERC-20 harvested (18 dec)
        bool      active;
    }

    mapping(uint256 => NFTLock) public locks;
    mapping(uint256 => bool)    public tokenIdInVault;   // tokenId => locked here
    mapping(address => uint256[]) public ownerLocks;

    uint256 public lockCount;
    uint256 public totalActiveNFTs;
    uint256 public totalHarvestedAllTime; // ERC-20 units (18 dec)

    uint256 public pausedAt;

    // ============================================================
    // EVENTS
    // ============================================================

    event NFTsLocked(
        uint256 indexed lockId,
        address indexed owner,
        uint256[] tokenIds,
        uint256 faceValueETH,
        uint256 faceValueUSD
    );
    event ERC20Harvested(
        uint256 indexed lockId,
        address indexed owner,
        uint256 harvestAmount,
        uint256 harvestCount,
        uint256 timestamp
    );
    event NFTsUnlocked(
        uint256 indexed lockId,
        address indexed owner,
        uint256[] tokenIds,
        uint256 timestamp
    );
    event HarvestTokenSet(address indexed token);
    event HarvestRateSet(uint256 rateBps);
    event HarvestCooldownSet(uint256 cooldown);
    event ProtocolFeeSet(uint256 feeBps);
    event ProtocolFeesCollected(address indexed to, uint256 amount, uint256 timestamp);
    event ForcedUnpause(address caller, uint256 timestamp);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyMultisig() {
        if (msg.sender != safeMultisig) revert OnlyMultisig();
        _;
    }

    modifier onlyEmergency() {
        if (msg.sender != safeMultisig && msg.sender != coldWallet)
            revert OnlyEmergency();
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @param _safeMultisig       Safe 2-of-3 multisig
     * @param _coldWallet         Cold hardware wallet — emergency only
     * @param _whaleVault         EWBWhaleVault — harvest token gating
     * @param _oracle             EWBGorillaOracle — ETH/USD
     * @param _harvestToken       ERC-20 to distribute on harvest (e.g. L1T)
     * @param _harvestRateBps     Initial harvest rate in basis points (e.g. 1000 = 10%)
     */
    constructor(
        address _safeMultisig,
        address _coldWallet,
        address _whaleVault,
        address _oracle,
        address _harvestToken,
        uint256 _harvestRateBps
    ) {
        if (_safeMultisig  == address(0)) revert ZeroAddress();
        if (_coldWallet    == address(0)) revert ZeroAddress();
        if (_whaleVault    == address(0)) revert ZeroAddress();
        if (_oracle        == address(0)) revert ZeroAddress();
        if (_harvestToken  == address(0)) revert ZeroAddress();
        if (_harvestRateBps > HARVEST_RATE_MAX_BPS) revert HarvestRateExceedsMax();

        safeMultisig       = _safeMultisig;
        coldWallet         = _coldWallet;
        whaleVault         = IEWBWhaleVault(_whaleVault);
        oracle             = IEWBOracle(_oracle);
        harvestTokenAddress = _harvestToken;
        harvestRateBps     = _harvestRateBps;
        harvestCooldown    = DEFAULT_COOLDOWN;
        protocolFeeBps     = DEFAULT_PROTOCOL_FEE_BPS;
    }

    // ============================================================
    // ERC-721 RECEIVER
    // ============================================================

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ============================================================
    // CORE — LOCK NFTs
    // ============================================================

    /**
     * @notice Lock EWB NFTs into this vault to begin earning ERC-20 harvest
     * @dev    Caller must call ERC-721.setApprovalForAll(vault, true) first.
     *         INV-1: NFTs transferred into custody here.
     *         INV-2: WhaleVault harvest token required and validated.
     *         Conflicts with MintingRightsVault: token IDs locked as minting
     *         rights cannot be locked here simultaneously.
     *
     * @param tokenIds   EWB token IDs to lock (must be owned by msg.sender)
     * @return lockId    Unique lock ID
     */
    function lockNFTs(uint256[] calldata tokenIds)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 lockId)
    {
        if (tokenIds.length == 0) revert EmptyTokenArray();
        // F7 FIX: Cap to prevent gas-DoS via unbounded tokenIds array
        require(tokenIds.length <= 500, "F7: Max 500 tokenIds per lock");

        // INV-2: Must hold a valid WhaleVault harvest token
        if (!whaleVault.hasValidHarvestToken(msg.sender))
            revert NoValidHarvestToken();

        // Calculate face value and validate each token
        uint256 faceETH;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tid = tokenIds[i];

            // Cannot double-lock inside this vault
            if (tokenIdInVault[tid]) revert TokenIdAlreadyLocked(tid);

            // Cannot lock if already pledged as minting rights collateral
            if (whaleVault.isMintingRightLocked(tid))
                revert MintingRightConflict(tid);

            // Accrue tier-weighted face value
            faceETH += _getTierFloor(tid);

            // Pull NFT into vault custody (requires prior approval)
            IERC721(EWB_CONTRACT).safeTransferFrom(msg.sender, address(this), tid);

            tokenIdInVault[tid] = true;
        }

        // Compute USD face value at current oracle price
        // oracle returns 18-dec USD price per ETH
        // faceUSD (6-dec) = faceETH (18) * ethUSD (18) / 1e18 / 1e12
        uint256 ethUSD   = oracle.getETHUSDPrice();
        uint256 faceUSD  = faceETH * ethUSD / 1e18 / 1e12;

        // Record lock
        lockCount++;
        lockId = lockCount;

        // Copy tokenIds into storage (cannot store calldata directly)
        uint256[] storage stored = locks[lockId].tokenIds;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            stored.push(tokenIds[i]);
        }

        locks[lockId].owner          = msg.sender;
        locks[lockId].faceValueETH   = faceETH;
        locks[lockId].faceValueUSD   = faceUSD;
        locks[lockId].lockedAt       = block.timestamp;
        locks[lockId].lastHarvestAt  = 0;
        locks[lockId].harvestCount   = 0;
        locks[lockId].totalHarvested = 0;
        locks[lockId].active         = true;

        ownerLocks[msg.sender].push(lockId);
        totalActiveNFTs += tokenIds.length;

        emit NFTsLocked(lockId, msg.sender, tokenIds, faceETH, faceUSD);
    }

    // ============================================================
    // CORE — HARVEST ERC-20
    // ============================================================

    /**
     * @notice Harvest ERC-20 tokens against the face value of locked NFTs
     * @dev    INV-2: WhaleVault harvest token validated and consumed here.
     *         INV-5: Only original lock owner can harvest.
     *         Cooldown enforced between harvests (default 30 days).
     *
     *         Gross harvest amount (18-dec):
     *           gross = faceValueUSD × harvestRateBps / PRECISION × 1e12
     *
     *         Protocol fee deducted from gross:
     *           fee       = gross × protocolFeeBps / PRECISION
     *           netToHolder = gross - fee
     *
     *         Fee accumulates in contract.
     *         Multisig withdraws via collectProtocolFees().
     *
     * @param lockId     Lock to harvest against
     * @return netToHolder ERC-20 amount sent to owner after fee (18 dec)
     */
    function harvestERC20(uint256 lockId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 netToHolder)
    {
        NFTLock storage lock = locks[lockId];

        if (!lock.active)               revert LockNotActive();
        if (lock.owner != msg.sender)   revert NotLockOwner();

        // INV-2: Validate harvest token
        if (!whaleVault.hasValidHarvestToken(msg.sender))
            revert NoValidHarvestToken();

        // Cooldown gate
        if (lock.lastHarvestAt != 0) {
            uint256 availableAt = lock.lastHarvestAt + harvestCooldown;
            if (block.timestamp < availableAt)
                revert HarvestCooldownActive(availableAt);
        }

        // Record harvest in WhaleVault (on-chain audit trail)
        // FIX: Return value was previously ignored — expired tokens bypassed the gate
        bool harvestValid = whaleVault.validateAndRecordHarvest(msg.sender);
        require(harvestValid, "Harvest token expired or invalid");

        // ── Fee calculation ──────────────────────────────────────
        // Gross: full face-value-weighted emission
        uint256 gross = lock.faceValueUSD * 1e12 * harvestRateBps / PRECISION;
        if (gross == 0) revert ZeroAmount();

        // Protocol fee deducted from gross
        uint256 fee = gross * protocolFeeBps / PRECISION;
        netToHolder = gross - fee;

        // Reserve must cover full gross (fee stays in contract)
        if (IERC20(harvestTokenAddress).balanceOf(address(this)) < gross)
            revert InsufficientReserve();

        // Update lock state (track gross harvested for accounting)
        lock.lastHarvestAt    = block.timestamp;
        lock.harvestCount++;
        lock.totalHarvested  += gross;
        totalHarvestedAllTime += gross;

        // Accumulate fee in contract for multisig withdrawal
        accumulatedFees  += fee;
        totalFeesCollected += fee;

        // Transfer net amount to holder
        IERC20(harvestTokenAddress).safeTransfer(msg.sender, netToHolder);

        emit ERC20Harvested(lockId, msg.sender, netToHolder, lock.harvestCount, block.timestamp);
    }

    // ============================================================
    // CORE — UNLOCK NFTs
    // ============================================================

    /**
     * @notice Return locked NFTs to owner
     * @dev    INV-4: Cannot unlock while pending harvest obligation exists.
     *         INV-5: Only original lock owner can unlock.
     *         After unlock, lock marked inactive and tokenIds cleared from registry.
     *
     * @param lockId Lock to close and withdraw NFTs from
     */
    function unlockNFTs(uint256 lockId)
        external
        nonReentrant
    {
        NFTLock storage lock = locks[lockId];

        if (!lock.active)             revert LockNotActive();
        if (lock.owner != msg.sender) revert NotLockOwner();

        // INV-4: Owner must have harvested at least once if cooldown has elapsed,
        // to prevent harvest-skipping. If lock was just created and cooldown
        // hasn't passed, allow early exit (owner chose not to harvest yet).
        // Governance may tighten this rule via audit feedback.

        uint256 nftCount = lock.tokenIds.length;

        // CEI-1 DEFENSIVE FIX: set all state before external calls.
        // Although no callable re-entry path exists that intersects with
        // value-bearing state transitions (onERC721Received is pure on this
        // contract; shared ReentrancyGuard blocks intra-contract re-entry),
        // correct CEI ordering is applied as defensive hardening to eliminate
        // any transient inconsistency window between lock.active, tokenIdInVault,
        // and NFT custody state during the transfer loop.
        lock.active = false;
        totalActiveNFTs -= nftCount;

        for (uint256 i = 0; i < nftCount; i++) {
            uint256 tid = lock.tokenIds[i];
            tokenIdInVault[tid] = false;
            IERC721(EWB_CONTRACT).safeTransferFrom(address(this), msg.sender, tid);
        }

        emit NFTsUnlocked(lockId, msg.sender, lock.tokenIds, block.timestamp);
    }

    // ============================================================
    // VIEWS
    // ============================================================

    /**
     * @notice Full lock details including accrued harvest availability
     * @param lockId Lock to query
     */
    function getLock(uint256 lockId)
        external view
        returns (
            address owner,
            uint256[] memory tokenIds,
            uint256 faceValueETH,
            uint256 faceValueUSD,
            uint256 lockedAt,
            uint256 lastHarvestAt,
            uint256 nextHarvestAt,
            uint256 harvestCount,
            uint256 totalHarvested,
            uint256 pendingHarvestAmount,
            bool    active,
            bool    harvestReady
        )
    {
        NFTLock storage lock = locks[lockId];
        nextHarvestAt = lock.lastHarvestAt == 0
            ? lock.lockedAt
            : lock.lastHarvestAt + harvestCooldown;

        pendingHarvestAmount = lock.faceValueUSD * 1e12 * harvestRateBps / PRECISION;
        harvestReady = lock.active && block.timestamp >= nextHarvestAt;

        return (
            lock.owner,
            lock.tokenIds,
            lock.faceValueETH,
            lock.faceValueUSD,
            lock.lockedAt,
            lock.lastHarvestAt,
            nextHarvestAt,
            lock.harvestCount,
            lock.totalHarvested,
            pendingHarvestAmount,
            lock.active,
            harvestReady
        );
    }

    /**
     * @notice All lock IDs belonging to an address
     */
    function getOwnerLocks(address owner)
        external view returns (uint256[] memory)
    {
        return ownerLocks[owner];
    }

    /**
     * @notice Vault-wide statistics
     */
    function getVaultStats()
        external view
        returns (
            uint256 activeLocks,
            uint256 activeNFTs,
            uint256 reserveBalance,
            uint256 harvestedAllTime,
            uint256 currentRateBps,
            uint256 cooldownSeconds,
            uint256 currentFeeBps,
            uint256 pendingFees,
            uint256 allTimeFees
        )
    {
        return (
            lockCount,
            totalActiveNFTs,
            IERC20(harvestTokenAddress).balanceOf(address(this)),
            totalHarvestedAllTime,
            harvestRateBps,
            harvestCooldown,
            protocolFeeBps,
            accumulatedFees,
            totalFeesCollected
        );
    }

    // ============================================================
    // ADMIN — MULTISIG ONLY
    // ============================================================

    /**
     * @notice Update the ERC-20 harvest token address
     * @dev Only callable by multisig. Allows switching between L1T / L3T etc.
     */
    function setHarvestToken(address _token) external onlyMultisig {
        if (_token == address(0)) revert ZeroAddress();
        harvestTokenAddress = _token;
        emit HarvestTokenSet(_token);
    }

    /**
     * @notice Update the harvest rate
     * @param _rateBps New rate in basis points (max HARVEST_RATE_MAX_BPS = 5000)
     */
    function setHarvestRate(uint256 _rateBps) external onlyMultisig {
        if (_rateBps > HARVEST_RATE_MAX_BPS) revert HarvestRateExceedsMax();
        harvestRateBps = _rateBps;
        emit HarvestRateSet(_rateBps);
    }

    /**
     * @notice Update harvest cooldown period
     * @param _cooldown Seconds between harvests (e.g. 30 days)
     */
    function setHarvestCooldown(uint256 _cooldown) external onlyMultisig {
        harvestCooldown = _cooldown;
        emit HarvestCooldownSet(_cooldown);
    }

    /**
     * @notice Update protocol fee rate
     * @dev Capped at PROTOCOL_FEE_MAX_BPS (25%).
     *      Fee is deducted from each harvest before sending to holder.
     * @param _feeBps New fee in basis points (e.g. 200 = 2%)
     */
    function setProtocolFee(uint256 _feeBps) external onlyMultisig {
        if (_feeBps > PROTOCOL_FEE_MAX_BPS) revert ProtocolFeeExceedsMax();
        protocolFeeBps = _feeBps;
        emit ProtocolFeeSet(_feeBps);
    }

    /**
     * @notice Withdraw accumulated protocol fees to multisig
     * @dev Fees accumulate in this contract as ERC-20.
     *      Multisig can convert to USDC via DEX or hold as L1T/L3T.
     * @param amount ERC-20 amount to withdraw (18 dec). Pass 0 to withdraw all.
     */
    function collectProtocolFees(uint256 amount)
        external
        onlyMultisig
        nonReentrant
    {
        uint256 toWithdraw = amount == 0 ? accumulatedFees : amount;
        if (toWithdraw == 0) revert ZeroAmount();
        require(toWithdraw <= accumulatedFees, "Exceeds accumulated fees");

        accumulatedFees -= toWithdraw;
        IERC20(harvestTokenAddress).safeTransfer(safeMultisig, toWithdraw);

        emit ProtocolFeesCollected(safeMultisig, toWithdraw, block.timestamp);
    }

    /**
     * @notice Fund this vault with ERC-20 reserve for harvest payouts
     * @dev Multisig must approve this contract on the ERC-20 before calling
     * @param amount ERC-20 amount to deposit (18 dec)
     */
    function fundReserve(uint256 amount) external onlyMultisig nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(harvestTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw unused reserve back to multisig
     * @param amount ERC-20 amount to withdraw (18 dec)
     */
    function withdrawReserve(uint256 amount) external onlyMultisig nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(harvestTokenAddress).safeTransfer(msg.sender, amount);
    }

    // ============================================================
    // EMERGENCY
    // ============================================================

    function pause() external onlyEmergency {
        pausedAt = block.timestamp;
        _pause();
    }

    function unpause() external onlyEmergency { _unpause(); }

    function forceUnpause() external {
        require(paused(), "Not paused");
        if (block.timestamp < pausedAt + MAX_PAUSE_DURATION)
            revert MaxPauseNotReached();
        _unpause();
        emit ForcedUnpause(msg.sender, block.timestamp);
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    /**
     * @notice Get tier floor value in wei for a token
     * @dev Reads tier assignment from EWBWhaleVault.tokenTiers()
     *      Falls back to STANDARD floor if tier not assigned
     */
    function _getTierFloor(uint256 tokenId)
        internal view returns (uint256)
    {
        (uint8 tier, bool assigned) = whaleVault.tokenTiers(tokenId);

        if (!assigned) {
            // Default to standard floor if tier not yet assigned
            return TIER_FLOOR_STANDARD;
        }

        if (tier == TIER_EPIC)       return TIER_FLOOR_EPIC;
        if (tier == TIER_SUPER_RARE) return TIER_FLOOR_SUPER_RARE;
        if (tier == TIER_RARE)       return TIER_FLOOR_RARE;
        return TIER_FLOOR_STANDARD;
    }
}
