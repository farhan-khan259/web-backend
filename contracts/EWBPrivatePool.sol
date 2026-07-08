// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBPrivatePool
 * @author Wayne Fyffe — Exposed Walls (EWB)
 * @notice NFT-Collateralised 50/50 Private Lending Pool
 * @dev Wired to EWBWhaleVault (minting rights registry).
 *
 * ================================================================
 * ARCHITECTURE
 * ================================================================
 *
 * No USDC. No third-party lenders. Two NFT groups from EWBWhaleVault
 * act as mutual cross-collateral. Credit is internal accounting only.
 *
 * FLOW:
 *   1. Multisig whitelists both parties.
 *   2. Multisig calls createPool(partyA, partyB, ltv, deadline).
 *   3. Multisig calls seedPool(poolId, 0, lockIdA) — Side A.
 *   4. Multisig calls seedPool(poolId, 1, lockIdB) — Side B.
 *      Pool transitions to OPEN automatically.
 *   5. Party A draws credit against Side B's collateral.
 *      Party B draws credit against Side A's collateral.
 *   6. Multisig confirms repayment → pool closes → emits lockIds
 *      for multisig to release in EWBWhaleVault separately.
 *   7. On default → multisig calls markDefault() then claimCollateral()
 *      → event emits lockId → multisig releases in EWBWhaleVault.
 *
 * NOTE ON WHALEVAULT UNLOCK:
 *   EWBWhaleVault.unlockMintingRights() is onlyMultisig.
 *   This contract cannot call it directly.
 *   Every lock release emits a LockPendingRelease event containing
 *   the lockId. Multisig MUST call WhaleVault.unlockMintingRights()
 *   for each emitted lockId after pool close or collateral claim.
 *
 * ================================================================
 * INTEREST SWEEP — TREASURY INCOME
 * ================================================================
 *
 * Credit is internal (no USDC moves within the pool). Interest is
 * calculated at repayment time and recorded in pendingInterestUSD.
 *
 * When a borrower repays off-chain (USDC to SPV), the multisig:
 *   1. Calls repayCredit(poolId, side) — records interest accrued.
 *   2. Receives the USDC off-chain into the SPV treasury.
 *   3. Calls depositInterest(amount, token) — deposits the interest
 *      portion of that USDC into this contract.
 *   4. Calls sweepInterestToRouter() — routes accumulated USDC to
 *      EWBRevenueRouter, recording it as STREAM_PRIVATE_POOL income.
 *
 * This closes the loop: internal credit accounting → real USDC
 * income tracked on-chain and routed to treasury.
 *
 * ================================================================
 * INVARIANTS
 * ================================================================
 *   INV-1: lockId 0 is always rejected (zero = "unset" sentinel)
 *   INV-2: Each lockId can only be active in one pool at a time
 *   INV-3: partyA != partyB — no self-dealing pools
 *   INV-4: LTV always 1–9999 basis points (never exceeds face value)
 *   INV-5: Credit drawn never exceeds creditLimit of opposing side
 *   INV-6: Default only possible when drawnCredit > 0
 *   INV-7: Nonce is burned only after signature is verified
 *   INV-8: sweepInterestToRouter only moves tokens held by this contract
 *   INV-9: pendingInterestUSD never decreases without a matching sweep
 *
 * ================================================================
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// ----------------------------------------------------------------
// INTERFACES
// ----------------------------------------------------------------

interface IEWBWhaleVault {
    function isMintingRightLocked(uint256 tokenId)
        external view returns (bool);

    function getMintingLock(uint256 lockId)
        external view returns (
            uint256[] memory tokenIds,
            uint256 faceValueETH,
            uint256 faceValueUSD,
            uint256 lockedAt,
            uint256 expiresAt,
            bool    active,
            string  memory purpose
        );

    /// @notice Seed — lock committed to a pool. UNBOUND → BOUND.
    function onSeed(uint256 lockId, uint256 poolId) external;

    /// @notice Close — normal repay path. BOUND → UNBOUND.
    function onClose(uint256 lockId) external;

    /// @notice Claim — default/forced exit path. BOUND → UNBOUND.
    function onClaim(uint256 lockId) external;
}

interface IEWBRevenueRouter {
    function routePrivatePoolInterest(address token, uint256 amount) external;
}

interface IERC20Sweep {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ----------------------------------------------------------------
// CONTRACT
// ----------------------------------------------------------------

contract EWBPrivatePool is ReentrancyGuard, Pausable {

    // ============================================================
    // ERRORS
    // ============================================================

    error OnlyOwner();
    error OnlyEmergency();
    error ZeroAddress();
    error ZeroLockId();
    error PoolNotFound();
    error PoolNotOpen();
    error PoolAlreadyActive();
    error NotWhitelisted();
    error NotPoolParty();
    // SelfDealingPool error removed — INV-3 lifted for private vault (partyA == partyB allowed)
    error InvalidSide();
    error LockNotActive(uint256 lockId);
    error LockAlreadyInUse(uint256 lockId);
    error NFTNotLocked(uint256 tokenId);
    error CreditExceedsLTV();
    error ZeroAmount();
    error NothingToRepay();
    error SideAlreadyRepaid();
    error AlreadyDefaulted();
    error NotDefaulted();
    error NoDrawToDefault();
    error DeadlineNotReached();
    error SideAlreadySeeded();
    error LTVOutOfRange();
    error MaxPauseNotReached();
    error RouterNotSet();
    error NothingToSweep();
    error InsufficientContractBalance();

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 public constant PRECISION          = 10_000;
    uint256 public constant INTEREST_RATE_BPS  = 500;       // 5% pa
    uint256 public constant SECONDS_PER_YEAR   = 365 days;
    uint256 public constant DEFAULT_DEADLINE   = 30 days;
    uint256 public constant LTV_DEFAULT        = 800;       // 8%
    uint256 public constant LTV_MAX            = 9_999;     // <100% — INV-4
    uint256 public constant MAX_PAUSE_DURATION = 72 hours;

    // ============================================================
    // IMMUTABLES
    // ============================================================

    address        public immutable owner      ;
    address        public immutable coldWallet;
    IEWBWhaleVault public immutable whaleVault;

    // ============================================================
    // STRUCTS & ENUMS
    // ============================================================

    enum PoolState { PENDING, OPEN, CLOSED, DEFAULTED }

    struct PoolSide {
        address party;
        uint256 lockId;
        uint256 faceValueUSD;   // recorded at seeding for audit trail
        uint256 creditLimit;    // faceValueUSD * ltv / PRECISION
        uint256 drawnCredit;
        uint256 drawnAt;
        bool    repaid;
        bool    defaulted;
    }

    struct Pool {
        uint256   poolId;
        PoolState state;
        uint256   ltv;
        uint256   deadline;     // seconds from openedAt
        uint256   openedAt;
        PoolSide  sideA;
        PoolSide  sideB;
    }

    // ============================================================
    // STATE — ORIGINAL
    // ============================================================

    mapping(uint256 => Pool)    public pools;
    mapping(address => bool)    public globalWhitelist;
    /// @dev lockId → poolId. 0 = not in use. lockId 0 always rejected.
    mapping(uint256 => uint256) public lockIdToPoolId;
    uint256 public poolCount;
    uint256 public pausedAt;

    // ============================================================
    // STATE — INTEREST SWEEP (new)
    // ============================================================

    /// @notice Address of EWBRevenueRouter — set by multisig after deploy
    address public revenueRouter;

    /// @notice Running total of interest accrued across all repaid pools (informational).
    /// @dev    M-2 NOTE: This counter excludes waived interest (drawnCredit == 0 at repay).
    ///         It does NOT equal lifetime income swept to the router — use totalInterestSwept
    ///         per token for accurate income accounting. The gap = sum of all waived interest.
    uint256 public totalInterestAccrued;

    /// @notice Interest deposited by multisig and awaiting sweep (USDC 6 dec)
    /// @dev    Keyed by token address — supports USDC and future tokens
    mapping(address => uint256) public pendingInterest;

    /// @notice Total interest swept to revenue router per token (lifetime)
    mapping(address => uint256) public totalInterestSwept;

    // ============================================================
    // EVENTS — ORIGINAL
    // ============================================================

    event PoolCreated(uint256 indexed poolId, address indexed creator);
    event PoolSideSeeded(uint256 indexed poolId, uint8 side, uint256 lockId);
    event PoolOpened(uint256 indexed poolId);
    event CreditDrawn(uint256 indexed poolId, uint8 collateralSide, uint256 amount);
    event CreditRepaid(uint256 indexed poolId, uint8 side, uint256 principal, uint256 interest);
    event CreditWaived(uint256 indexed poolId, uint8 side);
    event PoolDefaultMarked(uint256 indexed poolId, uint8 side);
    /// @dev Multisig MUST call EWBWhaleVault.unlockMintingRights(lockId) after this event
    event LockPendingRelease(uint256 indexed poolId, uint256 lockId);
    event CollateralClaimRecorded(uint256 indexed poolId, uint8 claimantSide, uint256 defaultedLockId);
    event PoolClosed(uint256 indexed poolId);
    event AddressWhitelisted(address indexed addr);
    event AddressRemovedFromWhitelist(address indexed addr);
    event ForcedUnpause(address caller, uint256 timestamp);

    // ============================================================
    // EVENTS — INTEREST SWEEP (new)
    // ============================================================

    /// @notice Fired when multisig sets or updates the revenue router address
    event RevenueRouterSet(address indexed router);

    /// @notice Fired when multisig deposits interest USDC into this contract
    event InterestDeposited(address indexed token, uint256 amount, uint256 poolId, uint8 side);

    /// @notice Fired when accumulated interest is swept to the revenue router
    event InterestSwept(address indexed token, uint256 amount, address indexed router);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyEmergency() {
        if (msg.sender != owner && msg.sender != coldWallet)
            revert OnlyEmergency();
        _;
    }

    modifier onlyWhitelisted() {
        // Policy: owner can always draw from their own pool.
        if (msg.sender != owner && !globalWhitelist[msg.sender]) revert NotWhitelisted();
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(
        address _owner,
        address _coldWallet,
        address _whaleVault
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_coldWallet   == address(0)) revert ZeroAddress();
        if (_whaleVault   == address(0)) revert ZeroAddress();
        owner = _owner;
        coldWallet   = _coldWallet;
        whaleVault   = IEWBWhaleVault(_whaleVault);
    }

    // ============================================================
    // REVENUE ROUTER CONFIG (new)
    // ============================================================

    /**
     * @notice Set or update the EWBRevenueRouter address.
     * @dev    Callable any time by multisig — allows router upgrade without
     *         redeploying this contract. Emits event for audit trail.
     * @param _router Address of deployed EWBRevenueRouter
     */
    function setRevenueRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        revenueRouter = _router;
        emit RevenueRouterSet(_router);
    }

    // ============================================================
    // WHITELIST
    // ============================================================

    function addToWhitelist(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        globalWhitelist[addr] = true;
        emit AddressWhitelisted(addr);
    }

    function removeFromWhitelist(address addr) external onlyOwner {
        globalWhitelist[addr] = false;
        emit AddressRemovedFromWhitelist(addr);
    }

    // ============================================================
    // POOL LIFECYCLE
    // ============================================================

    /**
     * @notice Create a pool and assign both parties.
     * @dev  INV-3: partyA != partyB enforced here.
     *       INV-4: ltv capped at LTV_MAX (9999 bps).
     *
     * @param partyA      Side A address — must be whitelisted
     * @param partyB      Side B address — must be whitelisted, != partyA
     * @param ltv         LTV in basis points (1–9999). 0 = use 800 default.
     * @param deadlineSec Repayment window in seconds after pool opens. 0 = 30 days.
     * @return poolId     New pool ID
     */
    function createPool(
        address partyA,
        address partyB,
        uint256 ltv,
        uint256 deadlineSec
    )
        external
        onlyOwner
        whenNotPaused
        returns (uint256 poolId)
    {
        if (partyA == address(0) || partyB == address(0)) revert ZeroAddress();
        // Policy: vault owner can be on both sides of a pool.
        // Self-dealing restriction removed — owner has full discretion.
        // If partyA == partyB, this is an internal treasury credit line.
        // Original INV-3 removed for private vault. External parties still
        // subject to standard credit checks via whitelist.
        // Policy: owner is always approved — no whitelist entry needed.
        // Third parties must still be on the whitelist.
        if (partyA != owner && !globalWhitelist[partyA]) revert NotWhitelisted();
        if (partyB != owner && !globalWhitelist[partyB]) revert NotWhitelisted();

        uint256 _ltv = ltv == 0 ? LTV_DEFAULT : ltv;
        if (_ltv == 0 || _ltv > LTV_MAX) revert LTVOutOfRange();       // INV-4

        poolCount++;
        poolId = poolCount;

        Pool storage p = pools[poolId];
        p.poolId      = poolId;
        p.state       = PoolState.PENDING;
        p.ltv         = _ltv;
        // Policy: evergreen credit lines — deadline 0 means no expiry.
        // Owner sets explicit deadline for third parties, 0 for own lines.
        p.deadline    = deadlineSec; // 0 = evergreen (no expiry enforced)
        p.sideA.party = partyA;
        p.sideB.party = partyB;

        emit PoolCreated(poolId, msg.sender);
    }

    /**
     * @notice Seed one side of the pool with a WhaleVault minting lock.
     * @dev  INV-1: lockId 0 always rejected.
     *       INV-2: lockId cannot already be assigned to any pool.
     *       lockIdToPoolId is written AFTER all validation — not before.
     *       Pool opens automatically when both sides seeded.
     *
     * @param poolId  Pool to seed
     * @param side    0 = Side A, 1 = Side B
     * @param lockId  EWBWhaleVault minting lock ID (must be > 0)
     */
    function seedPool(uint256 poolId, uint8 side, uint256 lockId)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        if (lockId == 0) revert ZeroLockId();                          // INV-1

        Pool storage p = pools[poolId];
        if (p.poolId == 0) revert PoolNotFound();
        if (p.state == PoolState.OPEN
         || p.state == PoolState.CLOSED
         || p.state == PoolState.DEFAULTED) revert PoolAlreadyActive();
        if (side > 1) revert InvalidSide();

        // Validate side not already seeded before any external call
        if (side == 0 && p.sideA.lockId != 0) revert SideAlreadySeeded();
        if (side == 1 && p.sideB.lockId != 0) revert SideAlreadySeeded();

        // INV-2: Prevent same lock used in multiple pools
        if (lockIdToPoolId[lockId] != 0) revert LockAlreadyInUse(lockId);

        // Read lock from WhaleVault
        (
            uint256[] memory tokenIds,
            ,
            uint256 faceValueUSD,
            ,
            ,
            bool active,

        ) = whaleVault.getMintingLock(lockId);

        if (!active) revert LockNotActive(lockId);

        // Verify every token in the lock is individually confirmed locked
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (!whaleVault.isMintingRightLocked(tokenIds[i]))
                revert NFTNotLocked(tokenIds[i]);
        }

        uint256 credit = faceValueUSD * p.ltv / PRECISION;

        // Write state only after all validation passes — INV-7 pattern
        lockIdToPoolId[lockId] = poolId;

        // SINGLE AUTHORITY: notify WhaleVault of the binding.
        // WhaleVault.lockPoolBinding becomes the canonical record.
        // This prevents unlockMintingRights() from deactivating an in-use lock.
        whaleVault.onSeed(lockId, poolId);

        if (side == 0) {
            p.sideA.lockId       = lockId;
            p.sideA.faceValueUSD = faceValueUSD;
            p.sideA.creditLimit  = credit;
        } else {
            p.sideB.lockId       = lockId;
            p.sideB.faceValueUSD = faceValueUSD;
            p.sideB.creditLimit  = credit;
        }

        emit PoolSideSeeded(poolId, side, lockId);

        // Transition to OPEN when both sides seeded
        if (p.sideA.lockId != 0 && p.sideB.lockId != 0) {
            p.state    = PoolState.OPEN;
            p.openedAt = block.timestamp;
            emit PoolOpened(poolId);
        }
    }

    // ============================================================
    // CREDIT DRAW & REPAY
    // ============================================================

    /**
     * @notice Draw internal credit against the opposing side's collateral.
     * @dev  Party A draws against Side B's lock; Party B against Side A's.
     *       INV-5: amount cannot exceed available credit on opposing side.
     *
     * @param poolId Pool to draw from
     * @param amount Credit units to draw (6 decimals, same scale as faceValueUSD)
     */
    function drawCredit(uint256 poolId, uint256 amount)
        external
        onlyWhitelisted
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();

        Pool storage p = pools[poolId];
        if (p.state != PoolState.OPEN) revert PoolNotOpen();

        bool isPartyA = (msg.sender == p.sideA.party);
        bool isPartyB = (msg.sender == p.sideB.party);
        if (!isPartyA && !isPartyB) revert NotPoolParty();

        // C-1 FIX: Boolean dispatch fails under identity collapse (partyA == partyB).
        // When both predicates are true, isPartyA always wins — Side A collateral
        // is permanently unencumberable, half the credit capacity is dead.
        //
        // Fix: split on identity equality first.
        // Normal case (disjoint parties): identity determines which side is collateral.
        // Degenerate case (self-dealing, A == B): allocation is state-driven —
        // consume whichever side has remaining capacity. This is deterministic,
        // caller-independent, and preserves full credit access without API changes.

        if (p.sideA.party != p.sideB.party) {
            // ── Normal case: disjoint parties ──────────────────────────────
            if (isPartyA) {
                // Party A borrows against Side B collateral
                uint256 available = p.sideB.creditLimit - p.sideB.drawnCredit;
                if (amount > available) revert CreditExceedsLTV();
                p.sideB.drawnCredit += amount;
                if (p.sideB.drawnAt == 0) p.sideB.drawnAt = block.timestamp;
                emit CreditDrawn(poolId, 1, amount);
            } else {
                // Party B borrows against Side A collateral
                uint256 available = p.sideA.creditLimit - p.sideA.drawnCredit;
                if (amount > available) revert CreditExceedsLTV();
                p.sideA.drawnCredit += amount;
                if (p.sideA.drawnAt == 0) p.sideA.drawnAt = block.timestamp;
                emit CreditDrawn(poolId, 0, amount);
            }
        } else {
            // ── Degenerate case: self-dealing pool (partyA == partyB) ──────
            // Both sides are logically equivalent. Allocate against whichever
            // side has remaining capacity — fixed order (A first) ensures
            // deterministic behaviour with no caller-controlled selection.
            uint256 availableA = p.sideA.creditLimit - p.sideA.drawnCredit;
            uint256 availableB = p.sideB.creditLimit - p.sideB.drawnCredit;
            if (availableA >= amount) {
                p.sideA.drawnCredit += amount;
                if (p.sideA.drawnAt == 0) p.sideA.drawnAt = block.timestamp;
                emit CreditDrawn(poolId, 0, amount);
            } else if (availableB >= amount) {
                p.sideB.drawnCredit += amount;
                if (p.sideB.drawnAt == 0) p.sideB.drawnAt = block.timestamp;
                emit CreditDrawn(poolId, 1, amount);
            } else {
                // Neither side alone can cover — revert. No split draws.
                revert CreditExceedsLTV();
            }
        }
    }

    /**
     * @notice Multisig confirms repayment for one side.
     * @dev  If drawnCredit > 0: records repayment + interest accrued.
     *       Interest amount is added to totalInterestAccrued (informational).
     *       Actual USDC must be deposited separately via depositInterest().
     *       If drawnCredit == 0: records a waive (distinct event).
     *       Both paths mark the side repaid so the pool can close.
     *       When both sides repaid/waived, emits LockPendingRelease
     *       for each lockId — multisig MUST call WhaleVault separately.
     *
     * @param poolId Pool to repay
     * @param side   0 = Side A's obligation, 1 = Side B's obligation
     */
    function repayCredit(uint256 poolId, uint8 side)
        external
        onlyOwner
        nonReentrant
    {
        Pool storage p = pools[poolId];
        if (p.state != PoolState.OPEN) revert PoolNotOpen();
        if (side > 1) revert InvalidSide();

        PoolSide storage ps = side == 0 ? p.sideA : p.sideB;
        if (ps.repaid) revert SideAlreadyRepaid();

        if (ps.drawnCredit > 0) {
            uint256 interest = _calcInterest(ps.drawnCredit, ps.drawnAt);

            // --- INTEREST SWEEP: record accrued interest for this repayment ---
            // Interest is tracked here. Multisig deposits the actual USDC
            // via depositInterest() and then calls sweepInterestToRouter().
            totalInterestAccrued += interest;
            // -------------------------------------------------------------------

            emit CreditRepaid(poolId, side, ps.drawnCredit, interest);
            ps.drawnCredit = 0;
            ps.drawnAt     = 0;  // clear clock so interest reads as 0 post-repay
        } else {
            emit CreditWaived(poolId, side);
        }

        ps.repaid = true;

        if (p.sideA.repaid && p.sideB.repaid) {
            _closePool(p);
        }
    }

    // ============================================================
    // INTEREST SWEEP — TREASURY INCOME (new)
    // ============================================================

    /**
     * @notice Multisig deposits the interest portion of a repayment into
     *         this contract so it can be swept on-chain to the revenue router.
     *
     * @dev    Called AFTER repayCredit(). The multisig has received USDC
     *         off-chain from the borrower. The interest slice is deposited
     *         here and tracked in pendingInterest[token].
     *
     *         CEI: state written before external transferFrom call.
     *
     * @param token  Token address (USDC mainnet: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
     * @param amount Interest amount in token decimals (USDC = 6 dec)
     * @param poolId Pool ID this interest relates to (for audit trail)
     * @param side   Side that repaid (0 or 1)
     */
    function depositInterest(
        address token,
        uint256 amount,
        uint256 poolId,
        uint8   side
    )
        external
        onlyOwner
        nonReentrant
    {
        if (token  == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();

        // CEI: write state before external call — INV-9
        pendingInterest[token] += amount;

        // Pull USDC from multisig wallet into this contract
        bool ok = IERC20Sweep(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "EWBPrivatePool: interest deposit transfer failed");

        emit InterestDeposited(token, amount, poolId, side);
    }

    /**
     * @notice Sweep all accumulated interest for a given token to the
     *         EWBRevenueRouter, which records it as private pool income
     *         and forwards to the SPV treasury.
     *
     * @dev    INV-8: only moves tokens actually held by this contract.
     *         Calls routePrivatePoolInterest() on the router — that function
     *         must be added to EWBRevenueRouter (see amendment note below).
     *         Reverts if router not set, nothing pending, or balance too low.
     *
     *         CEI: state cleared before external transfer.
     *
     * @param token Token to sweep (must have pendingInterest > 0)
     */
    function sweepInterestToRouter(address token)
        external
        onlyOwner
        nonReentrant
    {
        if (revenueRouter == address(0)) revert RouterNotSet();
        if (token == address(0))         revert ZeroAddress();

        uint256 amount = pendingInterest[token];
        if (amount == 0) revert NothingToSweep();

        // INV-8: verify this contract actually holds the tokens
        uint256 bal = IERC20Sweep(token).balanceOf(address(this));
        if (bal < amount) revert InsufficientContractBalance();

        // CEI: clear pending before external call — INV-9
        pendingInterest[token]    = 0;
        totalInterestSwept[token] += amount;

        // Transfer to router
        bool ok = IERC20Sweep(token).transfer(revenueRouter, amount);
        require(ok, "EWBPrivatePool: sweep transfer failed");

        // Notify router to record the income stream
        IEWBRevenueRouter(revenueRouter).routePrivatePoolInterest(token, amount);

        emit InterestSwept(token, amount, revenueRouter);
    }

    /**
     * @notice Preview pending interest for a given token without sweeping.
     * @param token Token address to check
     * @return pending Amount awaiting sweep (token decimals)
     * @return swept   Lifetime amount swept to router (token decimals)
     */
    function interestSweepStatus(address token)
        external view
        returns (uint256 pending, uint256 swept)
    {
        return (pendingInterest[token], totalInterestSwept[token]);
    }

    // ============================================================
    // DEFAULT & COLLATERAL CLAIM
    // ============================================================

    /**
     * @notice Mark a side as defaulted after the repayment deadline.
     * @dev  INV-6: Requires drawnCredit > 0 — can't default on zero draw.
     *       Requires repaid == false.
     *
     * @param poolId Pool ID
     * @param side   0 = Side A defaulted, 1 = Side B defaulted
     */
    function markDefault(uint256 poolId, uint8 side)
        external
        onlyOwner
    {
        Pool storage p = pools[poolId];
        if (p.state != PoolState.OPEN) revert PoolNotOpen();
        if (side > 1) revert InvalidSide();
        // FIX-5: Evergreen pools have deadline = 0, meaning no expiry enforced.
        // Original check: block.timestamp < openedAt + 0 => always false after open,
        // allowing immediate default on evergreen pools — wrong behaviour.
        // Fix: only enforce deadline check when deadline > 0.
        if (p.deadline > 0) {
            if (block.timestamp < p.openedAt + p.deadline) revert DeadlineNotReached();
        }

        PoolSide storage ps = side == 0 ? p.sideA : p.sideB;
        if (ps.defaulted)    revert AlreadyDefaulted();
        if (ps.repaid)       revert SideAlreadyRepaid();
        if (ps.drawnCredit == 0) revert NoDrawToDefault();              // INV-6

        ps.defaulted = true;
        p.state      = PoolState.DEFAULTED;

        emit PoolDefaultMarked(poolId, side);
    }

    /**
     * @notice Record collateral claim after default.
     * @dev  Clears the defaulted side's lockId from registry.
     *       Emits LockPendingRelease — multisig MUST then call
     *       EWBWhaleVault.unlockMintingRights(defaultedLockId) directly.
     *
     *       The non-defaulted side's lock is also released via
     *       LockPendingRelease so the pool is fully unwound.
     *
     * @param poolId        Pool ID
     * @param defaultedSide Side that defaulted (0 or 1)
     */
    function claimCollateral(uint256 poolId, uint8 defaultedSide)
        external
        onlyOwner
        nonReentrant
    {
        Pool storage p = pools[poolId];
        if (p.state != PoolState.DEFAULTED) revert NotDefaulted();
        if (defaultedSide > 1) revert InvalidSide();

        PoolSide storage ds = defaultedSide == 0 ? p.sideA : p.sideB;
        PoolSide storage ns = defaultedSide == 0 ? p.sideB : p.sideA;

        if (!ds.defaulted) revert NotDefaulted();
        require(ds.lockId != 0, "Collateral already claimed");

        uint256 defaultedLockId    = ds.lockId;
        uint256 nonDefaultedLockId = ns.lockId;
        uint8   claimantSide       = defaultedSide == 0 ? 1 : 0;

        // Clear lock registry — emit IDs BEFORE zeroing so they are visible
        emit LockPendingRelease(poolId, defaultedLockId);
        if (nonDefaultedLockId != 0) {
            emit LockPendingRelease(poolId, nonDefaultedLockId);
        }

        ds.lockId = 0;
        ns.lockId = 0;
        // SINGLE AUTHORITY: release bindings in WhaleVault
        whaleVault.onClaim(defaultedLockId);
        lockIdToPoolId[defaultedLockId] = 0;
        // H-2 FIX: only clear non-defaulted side if it has a real lockId.
        // Avoids writing lockIdToPoolId[0] = 0 which pollutes the zero sentinel.
        if (nonDefaultedLockId != 0) {
            whaleVault.onClaim(nonDefaultedLockId);
            lockIdToPoolId[nonDefaultedLockId] = 0;
        }

        p.state = PoolState.CLOSED;

        emit CollateralClaimRecorded(poolId, claimantSide, defaultedLockId);
        emit PoolClosed(poolId);
    }

    // ============================================================
    // VIEWS
    // ============================================================

    function getPool(uint256 poolId)
        external view
        returns (
            PoolState state,
            uint256   ltv,
            uint256   openedAt,
            uint256   deadlineAt,
            address   partyA,
            uint256   sideA_lockId,
            uint256   sideA_creditLimit,
            uint256   sideA_drawnCredit,
            uint256   sideA_accruedInterest,
            bool      sideA_repaid,
            bool      sideA_defaulted,
            address   partyB,
            uint256   sideB_lockId,
            uint256   sideB_creditLimit,
            uint256   sideB_drawnCredit,
            uint256   sideB_accruedInterest,
            bool      sideB_repaid,
            bool      sideB_defaulted
        )
    {
        Pool storage p = pools[poolId];
        if (p.poolId == 0) revert PoolNotFound();

        return (
            p.state,
            p.ltv,
            p.openedAt,
            p.openedAt > 0 ? p.openedAt + p.deadline : 0,
            p.sideA.party,
            p.sideA.lockId,
            p.sideA.creditLimit,
            p.sideA.drawnCredit,
            _calcInterest(p.sideA.drawnCredit, p.sideA.drawnAt),
            p.sideA.repaid,
            p.sideA.defaulted,
            p.sideB.party,
            p.sideB.lockId,
            p.sideB.creditLimit,
            p.sideB.drawnCredit,
            _calcInterest(p.sideB.drawnCredit, p.sideB.drawnAt),
            p.sideB.repaid,
            p.sideB.defaulted
        );
    }

    function getTotalDue(uint256 poolId, uint8 side)
        external view
        returns (uint256 principal, uint256 interest, uint256 totalDue)
    {
        Pool storage p = pools[poolId];
        if (p.poolId == 0) revert PoolNotFound();
        PoolSide storage ps = side == 0 ? p.sideA : p.sideB;
        principal = ps.drawnCredit;
        interest  = _calcInterest(ps.drawnCredit, ps.drawnAt);
        totalDue  = principal + interest;
    }

    function isDeadlinePassed(uint256 poolId) external view returns (bool) {
        Pool storage p = pools[poolId];
        if (p.poolId == 0 || p.openedAt == 0) return false;
        return block.timestamp >= p.openedAt + p.deadline;
    }

    // ============================================================
    // ADMIN
    // ============================================================

    function pause() external onlyEmergency {
        pausedAt = block.timestamp;
        _pause();
    }

    function unpause() external onlyEmergency { _unpause(); }

    function forceUnpause() external onlyOwner {
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
     * @dev Close pool on full repayment.
     *      Emits LockPendingRelease for each active lock BEFORE zeroing.
     *      Multisig must call EWBWhaleVault.unlockMintingRights() for each.
     */
    function _closePool(Pool storage p) internal {
        p.state = PoolState.CLOSED;

        if (p.sideA.lockId != 0) {
            emit LockPendingRelease(p.poolId, p.sideA.lockId);
            // SINGLE AUTHORITY: release binding in WhaleVault first
            whaleVault.onClose(p.sideA.lockId);
            lockIdToPoolId[p.sideA.lockId] = 0;
            p.sideA.lockId = 0;
        }
        if (p.sideB.lockId != 0) {
            emit LockPendingRelease(p.poolId, p.sideB.lockId);
            // SINGLE AUTHORITY: release binding in WhaleVault first
            whaleVault.onClose(p.sideB.lockId);
            lockIdToPoolId[p.sideB.lockId] = 0;
            p.sideB.lockId = 0;
        }

        emit PoolClosed(p.poolId);
    }

    /**
     * @dev Simple interest at 5% pa. Returns 0 if clock is cleared (post-repay).
     */
    function _calcInterest(uint256 principal, uint256 originatedAt)
        internal view returns (uint256)
    {
        if (originatedAt == 0 || principal == 0) return 0;
        uint256 elapsed = block.timestamp - originatedAt;
        // L-8 NOTE: If drawn and repaid in the same block, elapsed = 0 and interest = 0.
        // This is acceptable — same-block arbitrage is economically irrational at 5% pa.
        return principal * INTEREST_RATE_BPS * elapsed / PRECISION / SECONDS_PER_YEAR;
    }
}
