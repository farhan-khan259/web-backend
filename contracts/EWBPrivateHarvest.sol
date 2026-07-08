// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBPrivateHarvest
 * @author Wayne Fyffe — Exposed Walls (EWB)
 * @notice Token-ID-Only Private Harvest — Zero ETH Exposure
 *
 * ================================================================
 * SECURITY MODEL
 * ================================================================
 *
 *  THREAT              MITIGATION
 *  ──────────────────  ───────────────────────────────────────────
 *  ETH drain           No payable functions. Contract holds zero ETH.
 *  Replay attack       Nonce burned AFTER signature verified (INV-7).
 *  Signature forgery   ecrecover must match registered harvesterKey.
 *  Duplicate token IDs Per-request deduplication enforced on-chain.
 *  Credit inflation    MAX_CREDIT_PER_TOKEN constant enforced.
 *  Spoofed token IDs   Every ID verified via WhaleVault.isMintingRightLocked().
 *  Front-run           Two-step: submit (no value) then multisig confirms.
 *  Stale proof         sigTimestamp must be < SIG_MAX_AGE old.
 *  Unbounded arrays    Request IDs stored by count only; pagination on read.
 *
 * ================================================================
 * HARVEST FLOW
 * ================================================================
 *
 *  OFF-CHAIN (Keeper Bot — harvestBot.js):
 *    1. Bot reads token IDs from EWBWhaleVault (view call, no ETH)
 *    2. Bot builds: keccak256("EWB_HARVEST_V1", harvester,
 *                   keccak256(tokenIds[]), timestamp, nonce)
 *    3. Bot signs hash with harvesterKey private key
 *    4. Bot calls submitHarvestRequest(tokenIds, timestamp, nonce, sig)
 *
 *  ON-CHAIN — Step 1 (EWBPrivateHarvest):
 *    5. Signature verified (ecrecover == harvesterKey)
 *    6. Token IDs verified in WhaleVault + deduplicated
 *    7. Nonce burned (AFTER signature verified — INV-7)
 *    8. Request stored PENDING — no value moves
 *
 *  ON-CHAIN — Step 2 (Safe Multisig):
 *    9. Multisig calls confirmHarvest(requestId, creditPerToken)
 *   10. Token IDs re-verified (state may have changed)
 *   11. Internal credit units issued — no ETH, no USDC
 *
 * NOTE ON WHALEVAULT validateAndRecordHarvest():
 *   That function is onlyDeltaVault in EWBWhaleVault.
 *   EWBPrivateHarvest does NOT call it — harvest count is tracked
 *   internally here. To reconcile with WhaleVault, multisig must
 *   call WhaleVault.validateAndRecordHarvest() separately, or
 *   EWBPrivateHarvest must be registered as deltaVault in WhaleVault.
 *
 * ================================================================
 * INVARIANTS
 * ================================================================
 *   INV-1: harvesterKey set once — immutable after first set
 *   INV-2: Nonce burned only AFTER signature verified
 *   INV-3: Token IDs deduplicated per request
 *   INV-4: creditPerToken capped at MAX_CREDIT_PER_TOKEN
 *   INV-5: Request TTL enforced — auto-rejects after 24hr
 *
 * ================================================================
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// ----------------------------------------------------------------
// INTERFACE — only functions this contract actually calls
// ----------------------------------------------------------------

interface IEWBWhaleVault {
    function isMintingRightLocked(uint256 tokenId)
        external view returns (bool);
}

// ----------------------------------------------------------------
// CONTRACT
// ----------------------------------------------------------------

contract EWBPrivateHarvest is ReentrancyGuard, Pausable {

    // ============================================================
    // ERRORS
    // ============================================================

    error OnlyMultisig();
    error OnlyEmergency();
    error ZeroAddress();
    error HarvesterNotSet();
    error HarvesterAlreadySet();
    error NotWhitelisted();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error TokenNotLocked(uint256 tokenId);
    error DuplicateTokenId(uint256 tokenId);
    error NoTokenIds();
    error RequestNotFound();
    error RequestNotPending();
    error CreditPerTokenTooHigh();
    error MaxPauseNotReached();
    error InvalidSignatureLength();

    // ============================================================
    // CONSTANTS
    // ============================================================

    string  public constant DOMAIN             = "EWB_HARVEST_V1";
    uint256 public constant SIG_MAX_AGE        = 1 hours;
    uint256 public constant REQUEST_TTL        = 24 hours;
    uint256 public constant MAX_PAUSE_DURATION = 72 hours;
    /// @dev INV-4: cap prevents runaway credit minting
    uint256 public constant MAX_CREDIT_PER_TOKEN = 1_000_000e6; // 1M units (6 dec)

    // ============================================================
    // IMMUTABLES
    // ============================================================

    address        public immutable safeMultisig;
    address        public immutable coldWallet;
    IEWBWhaleVault public immutable whaleVault;

    // ============================================================
    // STATE
    // ============================================================

    /// @notice Off-chain bot key. Set once — INV-1.
    address public harvesterKey;

    /// @notice Burned nonces: keccak256(harvester, nonce) → used
    mapping(bytes32 => bool) public usedNonces;

    /// @notice Whitelisted submitters
    mapping(address => bool) public harvestWhitelist;

    /// @notice Internal credit balances (6 dec, no ETH/USDC)
    mapping(address => uint256) public harvestCredit;

    // ── Harvest Requests ─────────────────────────────────────────

    enum RequestState { PENDING, CONFIRMED, REJECTED }

    struct HarvestRequest {
        uint256      requestId;
        address      harvester;
        uint256[]    tokenIds;
        uint256      submittedAt;
        uint256      sigTimestamp;
        bytes32      nonce;
        RequestState state;
        uint256      creditAwarded;
    }

    mapping(uint256 => HarvestRequest) public requests;

    /// @dev Count only — no unbounded array per harvester (P2-06 fix)
    mapping(address => uint256) public harvesterRequestCount;

    uint256 public requestCount;
    uint256 public pausedAt;

    // ============================================================
    // EVENTS
    // ============================================================

    event HarvesterKeySet(address indexed key);
    event HarvestWhitelisted(address indexed harvester);
    event HarvestWhitelistRevoked(address indexed harvester);
    event HarvestRequestSubmitted(
        uint256 indexed requestId,
        address indexed harvester,
        uint256         tokenCount,
        uint256         sigTimestamp
    );
    event HarvestConfirmed(
        uint256 indexed requestId,
        address indexed harvester,
        uint256         creditAwarded
    );
    event HarvestRejected(uint256 indexed requestId, string reason);
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

    constructor(
        address _safeMultisig,
        address _coldWallet,
        address _whaleVault
    ) {
        if (_safeMultisig == address(0)) revert ZeroAddress();
        if (_coldWallet   == address(0)) revert ZeroAddress();
        if (_whaleVault   == address(0)) revert ZeroAddress();
        safeMultisig = _safeMultisig;
        coldWallet   = _coldWallet;
        whaleVault   = IEWBWhaleVault(_whaleVault);
    }

    // ============================================================
    // SETUP
    // ============================================================

    /**
     * @notice Register the off-chain bot key. One-time — INV-1.
     */
    function setHarvesterKey(address _key) external onlyMultisig {
        if (_key == address(0))         revert ZeroAddress();
        if (harvesterKey != address(0)) revert HarvesterAlreadySet();
        harvesterKey = _key;
        emit HarvesterKeySet(_key);
    }

    function addHarvester(address harvester) external onlyMultisig {
        if (harvester == address(0)) revert ZeroAddress();
        harvestWhitelist[harvester] = true;
        emit HarvestWhitelisted(harvester);
    }

    function removeHarvester(address harvester) external onlyMultisig {
        harvestWhitelist[harvester] = false;
        emit HarvestWhitelistRevoked(harvester);
    }

    // ============================================================
    // STEP 1 — SUBMIT REQUEST
    // ============================================================

    /**
     * @notice Submit a harvest request: token IDs + ECDSA proof.
     * @dev  No ETH moves. Stored PENDING until multisig confirms.
     *
     *       Signed payload (off-chain bot):
     *       keccak256("EWB_HARVEST_V1", harvester, keccak256(tokenIds[]),
     *                 sigTimestamp, nonce)
     *
     *       Security order (INV-2):
     *         1. Validate timestamp freshness
     *         2. Rebuild and verify signature
     *         3. Burn nonce (AFTER sig verified)
     *         4. Verify token IDs in WhaleVault
     *         5. Check for duplicate token IDs (INV-3)
     *         6. Store request
     *
     * @param tokenIds      NFT token IDs — must all be locked in WhaleVault
     * @param sigTimestamp  Timestamp from signed payload (must be < 1hr old)
     * @param nonce         Unique bytes32 — burned after verified use
     * @param signature     65-byte ECDSA signature from harvesterKey
     * @return requestId    ID of the pending request
     */
    function submitHarvestRequest(
        uint256[] calldata tokenIds,
        uint256            sigTimestamp,
        bytes32            nonce,
        bytes calldata     signature
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (harvesterKey == address(0))    revert HarvesterNotSet();
        if (!harvestWhitelist[msg.sender]) revert NotWhitelisted();
        if (tokenIds.length == 0)          revert NoTokenIds();

        // 1. Timestamp freshness
        if (sigTimestamp > block.timestamp) revert SignatureExpired();
        if (block.timestamp - sigTimestamp > SIG_MAX_AGE) revert SignatureExpired();

        // 2. Rebuild hash and verify signature BEFORE burning nonce — INV-2
        bytes32 idsHash  = keccak256(abi.encodePacked(tokenIds));
        // H6 FIX: Add chainId and address(this) to prevent cross-chain and
        // cross-deployment replay. Signature is now bound to this exact contract
        // on this exact chain. Testnet signatures cannot be replayed on mainnet.
        bytes32 dataHash = keccak256(abi.encodePacked(
            DOMAIN,
            block.chainid,      // chain binding — prevents cross-chain replay
            address(this),      // contract binding — prevents cross-deployment replay
            msg.sender,
            idsHash,
            sigTimestamp,
            nonce
        ));
        address recovered = _recoverSigner(dataHash, signature);
        if (recovered != harvesterKey) revert InvalidSignature();

        // 3. Burn nonce only after signature is verified — INV-2
        bytes32 nonceKey = keccak256(abi.encodePacked(msg.sender, nonce));
        if (usedNonces[nonceKey]) revert NonceAlreadyUsed();
        usedNonces[nonceKey] = true;

        // 4. Verify every token is locked in WhaleVault
        // 5. Deduplicate token IDs in the same pass — INV-3
        //    Uses a transient mapping via a per-call salt to avoid storage cost
        //    Pattern: mark seen IDs in a local bytes array checked by index
        uint256 len = tokenIds.length;
        uint256[] memory seen = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 tid = tokenIds[i];

            // Deduplication: scan seen array (gas-efficient for typical small batches)
            for (uint256 j = 0; j < i; j++) {
                if (seen[j] == tid) revert DuplicateTokenId(tid);
            }
            seen[i] = tid;

            if (!whaleVault.isMintingRightLocked(tid))
                revert TokenNotLocked(tid);
        }

        // 6. Store request
        requestCount++;
        requestId = requestCount;

        uint256[] memory ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = tokenIds[i];

        requests[requestId] = HarvestRequest({
            requestId:    requestId,
            harvester:    msg.sender,
            tokenIds:     ids,
            submittedAt:  block.timestamp,
            sigTimestamp: sigTimestamp,
            nonce:        nonce,
            state:        RequestState.PENDING,
            creditAwarded: 0
        });

        harvesterRequestCount[msg.sender]++;

        emit HarvestRequestSubmitted(requestId, msg.sender, len, sigTimestamp);
    }

    // ============================================================
    // STEP 2 — MULTISIG CONFIRMS OR REJECTS
    // ============================================================

    /**
     * @notice Confirm a pending harvest request and award internal credit.
     * @dev  Re-verifies token IDs (state may have changed since submit).
     *       INV-4: creditPerToken capped at MAX_CREDIT_PER_TOKEN.
     *       INV-5: auto-rejects if REQUEST_TTL exceeded.
     *
     *       NOTE: Does NOT call WhaleVault.validateAndRecordHarvest()
     *       because that function is onlyDeltaVault. Multisig must call
     *       WhaleVault directly to reconcile harvestCount if needed.
     *
     * @param requestId      Request to confirm
     * @param creditPerToken Internal credit units per token (6 dec, capped)
     */
    function confirmHarvest(uint256 requestId, uint256 creditPerToken)
        external
        onlyMultisig
        nonReentrant
        whenNotPaused
    {
        if (creditPerToken > MAX_CREDIT_PER_TOKEN) revert CreditPerTokenTooHigh(); // INV-4

        HarvestRequest storage req = requests[requestId];
        if (req.requestId == 0)                revert RequestNotFound();
        if (req.state != RequestState.PENDING) revert RequestNotPending();

        // INV-5: auto-reject on TTL
        if (block.timestamp > req.submittedAt + REQUEST_TTL) {
            req.state = RequestState.REJECTED;
            emit HarvestRejected(requestId, "TTL_EXPIRED");
            return;
        }

        // Re-verify all token IDs still locked
        for (uint256 i = 0; i < req.tokenIds.length; i++) {
            if (!whaleVault.isMintingRightLocked(req.tokenIds[i])) {
                req.state = RequestState.REJECTED;
                emit HarvestRejected(requestId, "TOKEN_UNLOCKED");
                return;
            }
        }

        uint256 credit    = req.tokenIds.length * creditPerToken;
        req.creditAwarded = credit;
        req.state         = RequestState.CONFIRMED;

        harvestCredit[req.harvester] += credit;

        emit HarvestConfirmed(requestId, req.harvester, credit);
    }

    /**
     * @notice Explicitly reject a pending request.
     * @param requestId Request to reject
     * @param reason    Short audit-trail string
     */
    function rejectHarvest(uint256 requestId, string calldata reason)
        external
        onlyMultisig
        nonReentrant
    {
        HarvestRequest storage req = requests[requestId];
        if (req.requestId == 0)                revert RequestNotFound();
        if (req.state != RequestState.PENDING) revert RequestNotPending();
        req.state = RequestState.REJECTED;
        emit HarvestRejected(requestId, reason);
    }

    // ============================================================
    // VIEWS
    // ============================================================

    function getRequest(uint256 requestId)
        external view
        returns (
            address      harvester,
            uint256[]    memory tokenIds,
            uint256      submittedAt,
            uint256      expiresAt,
            uint256      sigTimestamp,
            RequestState state,
            uint256      creditAwarded
        )
    {
        HarvestRequest storage req = requests[requestId];
        if (req.requestId == 0) revert RequestNotFound();
        return (
            req.harvester,
            req.tokenIds,
            req.submittedAt,
            req.submittedAt + REQUEST_TTL,
            req.sigTimestamp,
            req.state,
            req.creditAwarded
        );
    }

    /**
     * @notice Total number of requests submitted by a harvester.
     *         Use off-chain indexing of HarvestRequestSubmitted events
     *         to retrieve individual request IDs.
     */
    function getHarvesterRequestCount(address harvester)
        external view returns (uint256)
    {
        return harvesterRequestCount[harvester];
    }

    function getCreditBalance(address harvester)
        external view returns (uint256)
    {
        return harvestCredit[harvester];
    }

    function isNonceUsed(address harvester, bytes32 nonce)
        external view returns (bool)
    {
        return usedNonces[keccak256(abi.encodePacked(harvester, nonce))];
    }

    // ============================================================
    // ADMIN
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
    // INTERNAL — ECDSA
    // ============================================================

    function _recoverSigner(bytes32 dataHash, bytes memory signature)
        internal pure returns (address)
    {
        if (signature.length != 65) revert InvalidSignatureLength();
        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)
        );
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "Invalid v");
        return ecrecover(ethHash, v, r, s);
    }
}
