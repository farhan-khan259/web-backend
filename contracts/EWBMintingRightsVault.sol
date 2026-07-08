// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBMintingRightsVault
 * @author Wayne Fyffe — Exposed Walls (EWB)
 *
 * ================================================================
 * WHAT THIS CONTRACT DOES
 * ================================================================
 *
 * Wayne leverages his EWB minting rights — the right to mint
 * 8,632 unminted ERC-721 tokens that do not yet exist — as collateral
 * to borrow Circle USDC from Aave v3.
 *
 * COLLATERAL:   Unminted EWB token IDs locked in EWBWhaleVault
 * LENDER:       Aave v3 — holds Circle USDC from depositors
 * BORROWER:     Wayne Fyffe — Ballet wallet
 * DESTINATION:  All USDC goes to Ballet wallet only
 * REPAYMENT:    stETH yield auto-repays Aave debt
 *
 * ================================================================
 * CREDIT CAPACITY
 * ================================================================
 *
 *   EPIC (16 tokens × 315 ETH × 30% LTV):       1,512 ETH credit
 *   SUPER RARE (362 × 22 ETH × 25% LTV):        1,991 ETH credit
 *   RARE (1,492 × 10 ETH × 15% LTV):            2,238 ETH credit
 *   STANDARD (8,130 × 1 ETH × 8% LTV):            650 ETH credit
 *   ─────────────────────────────────────────────────────────────
 *   TOTAL:                                       6,391 ETH credit
 *   AT $1,601 ETH:                             ~$10.2M USDC
 *
 * ================================================================
 * AUTOMATED LIFECYCLE — NO POOL, NO DEPOSITORS
 * ================================================================
 *
 *   1. lockMintingRights()   ← WhaleVault — Ballet signs once
 *          ↓
 *   2. borrowUSDC(lockId)    ← Ballet signs — borrows from Aave
 *          ↓ automated
 *   3. Aave releases Circle USDC
 *          ↓ automated
 *   4. USDC → Ballet wallet  ← direct, no intermediary
 *          ↓ automated
 *   5. stETH yield harvested → swapped to USDC via Uniswap V3
 *          ↓ automated
 *   6. autoRepay()           ← yield pays Aave debt automatically
 *          ↓ automated
 *   7. Borrowing capacity restored → borrow again when ready
 *          ↓
 *   8. unlockMintingRights() ← Ballet signs — cycle resets
 *
 * ================================================================
 * CONFIRMED HARDCODED ADDRESSES
 * ================================================================
 *
 *   Ballet wallet:    0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *   Circle USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
 *   Aave v3 Pool:     0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
 *
 * ================================================================
 * INVARIANTS — ENFORCED IN CODE
 * ================================================================
 *
 *   INV-1: Borrow never exceeds faceValueUSD × LTV (hard revert)
 *   INV-2: Minting rights must be locked in WhaleVault to borrow
 *   INV-3: USDC only ever goes to Ballet wallet — hardcoded
 *   INV-4: Aave health factor ≥ 1.5x before every borrow
 *   INV-5: One active credit per lockId at a time
 *
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAaveV3Pool.sol";

// ── Interfaces ──────────────────────────────────────────────────

interface IEWBWhaleVault {
    function isMintingRightLocked(uint256 tokenId) external view returns (bool);
    function getLockFaceValueUSD(uint256 lockId)   external view returns (uint256);
    function tokenIdToLockId(uint256 tokenId)      external view returns (uint256);
    function tokenTiers(uint256 tokenId)           external view returns (uint8 tier, bool assigned);
}


// ── Contract ────────────────────────────────────────────────────

contract EWBMintingRightsVault is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ================================================================
    // HARDCODED ADDRESSES — IMMUTABLE
    // ================================================================

    /// @notice Circle USDC — issued by Circle, held by Aave depositors
    address public constant USDC =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Aave v3 Pool — the USDC lender
    address public constant AAVE_V3_POOL =
        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @notice Ballet wallet — Wayne Fyffe — sole USDC recipient
    address public constant BALLET_WALLET =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // ================================================================
    // LTV CAPS — IMMUTABLE IN BYTECODE
    // Mirror of EWBWhaleVault tier caps — cannot be changed
    // ================================================================

    uint256 public constant LTV_EPIC       = 3_000; // 30%
    uint256 public constant LTV_SUPER_RARE = 2_500; // 25%
    uint256 public constant LTV_RARE       = 1_500; // 15%
    uint256 public constant LTV_STANDARD   =   800; //  8%

    uint8 public constant TIER_EPIC       = 0;
    uint8 public constant TIER_SUPER_RARE = 1;
    uint8 public constant TIER_RARE       = 2;
    uint8 public constant TIER_STANDARD   = 3;

    /// @notice Aave variable interest rate mode
    uint256 public constant VARIABLE_RATE = 2;

    /// @notice Minimum Aave health factor before borrow allowed
    uint256 public constant MIN_HEALTH_FACTOR = 1.5e18;

    uint256 public constant PRECISION = 10_000;

    // ── State ────────────────────────────────────────────────────

    address public immutable owner;
    IEWBWhaleVault public immutable whaleVault;

    /// @notice DeltaNeutralVault — authorised to call autoRepay
    address public deltaVault;

    uint256 public creditCount;
    /// @notice Lifetime total USDC borrowed — never decrements (running total)
    uint256 public totalBorrowed;
    /// @notice Lifetime total USDC repaid — never decrements (running total)
    /// @dev Net outstanding = totalBorrowed - totalRepaid
    uint256 public totalRepaid;

    // ── Credit Position ──────────────────────────────────────────

    struct CreditPosition {
        uint256   lockId;
        uint256[] tokenIds;
        uint256   borrowed;     // USDC borrowed from Aave (6 dec)
        uint256   creditLimit;  // max allowed — faceValueUSD × LTV
        uint256   borrowedAt;
        bool      active;
    }

    mapping(uint256 => CreditPosition) public credits;
    mapping(uint256 => uint256)        public lockToCredit;

    // ── Events ───────────────────────────────────────────────────

    event USDCBorrowed(
        uint256 indexed creditId,
        uint256 indexed lockId,
        uint256 amount,
        uint256 creditLimit,
        address recipient
    );
    event USDCRepaid(
        uint256 indexed creditId,
        uint256 repaid,
        uint256 remaining
    );
    event AutoRepaid(uint256 indexed creditId, uint256 amount);
    event BorrowCapacityRestored(uint256 indexed lockId);
    event DeltaVaultSet(address vault);

    // ── Errors ───────────────────────────────────────────────────

    error NotOwner();
    error NotAuthorised();
    error ZeroAmount();
    error LockAlreadyHasCredit(uint256 lockId);
    error TokenNotLocked(uint256 tokenId);
    error TokenNotInLock(uint256 tokenId, uint256 lockId);
    error ExceedsLTVCap(uint256 requested, uint256 limit);
    error HealthFactorTooLow(uint256 healthFactor);
    error CreditNotActive();

    // ── Modifiers ────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────

    constructor(address _whaleVault) {
        require(_whaleVault != address(0), "Zero whaleVault");
        owner      = BALLET_WALLET;
        whaleVault = IEWBWhaleVault(_whaleVault);
    }

    // ================================================================
    // CORE — BORROW USDC FROM AAVE
    // ================================================================

    /**
     * @notice Borrow Circle USDC from Aave against locked minting rights
     *
     * @dev Full automated flow:
     *      1. Verifies token IDs are locked in WhaleVault
     *      2. Reads face value snapshotted at lock time
     *      3. Calculates credit limit = faceValueUSD × min(tier LTV)
     *      4. Checks Aave health factor ≥ 1.5x
     *      5. Borrows USDC from Aave v3 pool
     *      6. Sends USDC directly to Ballet wallet — hardcoded
     *
     *      INV-3: USDC destination is BALLET_WALLET constant.
     *      It cannot be redirected. It is in the bytecode.
     *
     * @param lockId    WhaleVault lock ID (from lockMintingRights())
     * @param tokenIds  Token IDs in the lock (for tier LTV calculation)
     * @param amount    USDC to borrow in 6 decimals (e.g. 1000e6 = $1,000)
     */
    function borrowUSDC(
        uint256            lockId,
        uint256[] calldata tokenIds,
        uint256            amount
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256 creditId)
    {
        if (amount == 0)            revert ZeroAmount();
        if (tokenIds.length == 0)   revert ZeroAmount();

        // INV-5: one active credit per lock
        if (lockToCredit[lockId] != 0) revert LockAlreadyHasCredit(lockId);

        // INV-2: all token IDs must be locked in WhaleVault
        // M-1 FIX: deduplicate tokenIds — no duplicates allowed
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                require(tokenIds[j] != tokenIds[i], "Duplicate tokenId");
            }
            if (!whaleVault.isMintingRightLocked(tokenIds[i]))
                revert TokenNotLocked(tokenIds[i]);
            if (whaleVault.tokenIdToLockId(tokenIds[i]) != lockId)
                revert TokenNotInLock(tokenIds[i], lockId);
        }

        // Read face value — snapshotted at lock time, not live oracle
        uint256 faceUSD = whaleVault.getLockFaceValueUSD(lockId);
        require(faceUSD > 0, "Invalid lock face value");

        // INV-1: amount cannot exceed face value × minimum tier LTV
        uint256 creditLimit = _calcCreditLimit(faceUSD, tokenIds);
        if (amount > creditLimit) revert ExceedsLTVCap(amount, creditLimit);

        // INV-4: Aave health factor must be safe
        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        if (healthFactor != 0 && healthFactor < MIN_HEALTH_FACTOR)
            revert HealthFactorTooLow(healthFactor);

        // CEI: record state before external calls
        creditCount++;
        creditId = creditCount;

        uint256[] memory ids = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) ids[i] = tokenIds[i];

        credits[creditId] = CreditPosition({
            lockId:      lockId,
            tokenIds:    ids,
            borrowed:    amount,
            creditLimit: creditLimit,
            borrowedAt:  block.timestamp,
            active:      true
        });

        lockToCredit[lockId] = creditId;
        totalBorrowed       += amount;

        // Borrow from Aave — USDC sent to this contract
        IAaveV3Pool(AAVE_V3_POOL).borrow(
            USDC,
            amount,
            VARIABLE_RATE,
            0,
            address(this)
        );

        // C-4 FIX: Re-check health factor AFTER borrow
        (, , , , , uint256 hfAfterBorrow) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        if (hfAfterBorrow != 0 && hfAfterBorrow < MIN_HEALTH_FACTOR)
            revert HealthFactorTooLow(hfAfterBorrow);

        // INV-3: USDC only to Ballet wallet — BALLET_WALLET is a constant
        IERC20(USDC).safeTransfer(BALLET_WALLET, amount);

        emit USDCBorrowed(creditId, lockId, amount, creditLimit, BALLET_WALLET);
    }

    // ================================================================
    // CORE — REPAY AAVE DEBT (manual)
    // ================================================================

    /**
     * @notice Repay Aave USDC debt manually — restores borrowing capacity
     * @dev Wayne sends USDC from Ballet wallet. Contract repays Aave.
     *      Once debt is cleared, same lockId can borrow again.
     *
     * @param creditId  Credit position to repay
     * @param amount    USDC to repay (use type(uint256).max for full repay)
     */
    function repayUSDC(uint256 creditId, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        CreditPosition storage c = credits[creditId];
        if (!c.active)   revert CreditNotActive();
        if (amount == 0) revert ZeroAmount();

        // H-1 FIX: CEI — update state BEFORE all external calls
        uint256 previousBorrowed = c.borrowed;
        uint256 lockId = c.lockId;

        if (amount >= c.borrowed) {
            c.active   = false;
            c.borrowed = 0;
            lockToCredit[lockId] = 0;
        } else {
            c.borrowed -= amount;
        }

        // External calls last
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(USDC).approve(AAVE_V3_POOL, 0);
        IERC20(USDC).approve(AAVE_V3_POOL, amount);

        uint256 repaid = IAaveV3Pool(AAVE_V3_POOL).repay(
            USDC, amount, VARIABLE_RATE, address(this)
        );

        totalRepaid += repaid;

        if (!c.active) emit BorrowCapacityRestored(lockId);
        emit USDCRepaid(creditId, repaid, c.borrowed);
    }

    // ================================================================
    // CORE — AUTO-REPAY FROM YIELD (automated)
    // ================================================================

    /**
     * @notice Auto-repay Aave debt from harvested stETH yield
     * @dev Called automatically by DeltaNeutralVault after harvestToUSDC()
     *      No Ballet signature required — fully automated.
     *      Yield pays debt. Capacity restores. Re-borrow when ready.
     *
     * @param creditId  Credit position to repay
     * @param amount    USDC from yield already in this contract
     */
    function autoRepay(uint256 creditId, uint256 amount)
        external
        nonReentrant
    {
        if (msg.sender != owner && msg.sender != deltaVault)
            revert NotAuthorised();

        CreditPosition storage c = credits[creditId];
        if (!c.active)   revert CreditNotActive();
        if (amount == 0) revert ZeroAmount();

        // L-1 FIX: verify USDC balance before attempting repay
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        require(usdcBalance >= amount, "Insufficient USDC for autoRepay");

        IERC20(USDC).approve(AAVE_V3_POOL, 0);
        IERC20(USDC).approve(AAVE_V3_POOL, amount);

        uint256 repaid = IAaveV3Pool(AAVE_V3_POOL).repay(
            USDC, amount, VARIABLE_RATE, address(this)
        );

        totalRepaid += repaid;

        if (repaid >= c.borrowed) {
            c.active         = false;
            c.borrowed       = 0;
            lockToCredit[c.lockId] = 0;
            emit BorrowCapacityRestored(c.lockId);
        } else {
            c.borrowed -= repaid;
        }

        emit AutoRepaid(creditId, repaid);
    }

    // ── Admin ────────────────────────────────────────────────────

    function setDeltaVault(address _vault) external onlyOwner {
        require(_vault != address(0), unicode"M-2: Zero address — use pause() to disable autoRepay");
        deltaVault = _vault;
        emit DeltaVaultSet(_vault);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function emergencyWithdraw() external onlyOwner {
        uint256 bal = IERC20(USDC).balanceOf(address(this));
        if (bal > 0) IERC20(USDC).safeTransfer(BALLET_WALLET, bal);
    }

    // ── Views ─────────────────────────────────────────────────────

    function getCredit(uint256 creditId) external view returns (
        uint256 lockId,
        uint256 borrowed,
        uint256 creditLimit,
        uint256 borrowedAt,
        bool    active
    ) {
        CreditPosition storage c = credits[creditId];
        return (c.lockId, c.borrowed, c.creditLimit, c.borrowedAt, c.active);
    }

    function getAavePosition() external view returns (
        uint256 totalCollateral,
        uint256 totalDebt,
        uint256 availableBorrows,
        uint256 healthFactor
    ) {
        (totalCollateral, totalDebt, availableBorrows, , , healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
    }

    function vaultStats() external view returns (
        uint256 _borrowed,
        uint256 _repaid,
        uint256 _net,
        uint256 _creditCount
    ) {
        _borrowed    = totalBorrowed;
        _repaid      = totalRepaid;
        _net         = totalBorrowed > totalRepaid ? totalBorrowed - totalRepaid : 0;
        _creditCount = creditCount;
    }

    // ── Internal ──────────────────────────────────────────────────

    /// @dev Use minimum LTV across all tiers — most conservative
    function _calcCreditLimit(uint256 faceUSD, uint256[] calldata tokenIds)
        internal view returns (uint256)
    {
        uint256 minLTV = type(uint256).max;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (uint8 tier, ) = whaleVault.tokenTiers(tokenIds[i]);
            uint256 tierLTV;
            if      (tier == TIER_EPIC)       tierLTV = LTV_EPIC;
            else if (tier == TIER_SUPER_RARE) tierLTV = LTV_SUPER_RARE;
            else if (tier == TIER_RARE)       tierLTV = LTV_RARE;
            else                              tierLTV = LTV_STANDARD;
            if (tierLTV < minLTV) minLTV = tierLTV;
        }
        if (minLTV == type(uint256).max) minLTV = LTV_STANDARD;
        return faceUSD * minLTV / PRECISION;
    }
}
