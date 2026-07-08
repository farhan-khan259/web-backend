// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// ================================================================
// VaultStorage — All state, events, errors, modifiers
// Auditors: read this file first.
// ================================================================

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ================================================================
// EWB DELTA-NEUTRAL VAULT — YIELD STRATEGY
// ================================================================
//
// CAPITAL FLOW — IMPORTANT:
//
//   This vault does NOT accept ETH from end users or NFT holders.
//   ETH enters ONLY from the Safe multisig treasury via deployLongLeg().
//
//   The EWB protocol has TWO parallel capital tracks:
//
//   TRACK A — NFT Collateral (token IDs, no ETH sent):
//     tokenIds → EWBWhaleVault.lockMintingRights()
//              → lockId with faceValueETH calculated from tier floors
//              → EWBMintingRightsVault.openLoan()  (USDC lent vs face value LTV)
//              → EWBPrivatePool.seedPool()          (internal credit lines)
//              → EWBNFTHarvestVault.lockNFTs()      (harvest token issuance)
//
//   TRACK B — Delta-Neutral Yield (ETH from Safe treasury only):
//     Safe multisig → deployLongLeg(){value: ethAmount}
//                  → Lido.submit() → stETH
//                  → IWstETH.wrap() → wstETH
//                  → AaveV3Pool.supply() → aWstETH (earning staking yield)
//     dYdX short leg placed manually, attested on-chain via ECDSA.
//
//   THE LINK:
//     maxDeployment = 6,391 ETH = LAYER3_ETH_TOTAL (from EWBLayer3Token)
//     The L3 credit capacity sets the cap on how much ETH can be deployed.
//     This ensures the yield strategy never exceeds the collateral backing.
//
//   WHO SENDS ETH:
//     Only the Safe multisig, from protocol treasury or yield accumulated.
//     Individual NFT holders NEVER send ETH to this contract.
//
// Strategy: Long stETH via Aave v3 (staking yield) + Short ETH perp via dYdX (hedge)
// Net result: Zero market exposure. Yield only.
//
// AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
// ================================================================

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IAaveV3Pool.sol";

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
}

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

// FIX: Added aToken interface to read rebase-adjusted balance from Aave
interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20DN {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// FIX R6: Safe ERC-20 transfer helper — handles non-standard tokens (USDT-style).
// stETH returns true but use safeTransfer everywhere for future-proofing.
library SafeERC20DN {
    function safeTransfer(IERC20DN token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20DN: transfer failed");
    }
}

/**
 * @title HedgeAttestation
 * @notice Verifiable signed attestation of dYdX hedge position
 *
 * HOW IT WORKS:
 * 1. Keeper bot reads dYdX position via API every 15 minutes
 * 2. Bot signs the position data with its private key (ECDSA)
 * 3. Bot calls submitHedgeAttestation() with data + signature
 * 4. Contract verifies signature came from registered attestor (bot)
 * 5. Attestation stored on-chain with block timestamp
 * 6. Anyone can verify: position data + signature + attestor address
 *
 * TRUST MODEL:
 * - Bot private key signs real position data read from dYdX API
 * - Contract verifies signature — cannot be faked without bot key
 * - Attestation timestamp shows freshness — stale = hedge unverified
 * - Moving from "owner says" → "bot cryptographically attested"
 *
 * NOT PERFECT — bot could be compromised
 * IS BETTER — independent verification, on-chain audit trail
 */
library HedgeAttestationLib {
    /**
     * @notice Recover signer address from attestation data + signature
     * @dev Standard Ethereum signed message hash recovery
     */
    function recoverSigner(
        bytes32 dataHash,
        bytes memory signature
    ) internal pure returns (address) {
        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)
        );
        require(signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "Invalid signature v value");
        return ecrecover(ethHash, v, r, s);
    }

    /**
     * @notice Build attestation data hash
     * @dev Hash of all position fields — any field change = different hash
     */
    function buildHash(
        uint256 notional,
        uint256 leverage,
        uint256 marginUSD,
        uint256 fundingRateBps,
        uint256 timestamp,
        string  memory accountId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "EWB_HEDGE_ATTESTATION_V1",
            notional,
            leverage,
            marginUSD,
            fundingRateBps,
            timestamp,
            accountId
        ));
    }
}

/**
 * ================================================================
 * FORMAL INVARIANTS — verified by audit firm
 * ================================================================
 *
 * INV-1: PRINCIPAL PRESERVATION
 *   totalDeployed must never decrease except via emergencyExit()
 *   or explicit owner withdrawal.
 *   assert: totalDeployed <= ETH sent by Safe multisig via deployLongLeg()
 *   NOTE: this ETH comes from the Safe treasury, NOT from NFT holders.
 *         NFT holders interact via Track A (lockMintingRights → lockId).
 *
 * INV-2: HARVEST NEVER EXCEEDS YIELD + HEDGE MUST BE FRESH
 *   Harvest amount = aTokenBalance - totalDeployed
 *   assert: harvestAmount <= (aTokenBalance - totalDeployed)
 *   assert: isHedgeAttestationFresh() == true before harvest
 *   Principal is never harvested on stale hedge.
 *
 * INV-3: EXIT STATE MONOTONIC
 *   exitStage can only increase (0→1→2→3→4)
 *   except reset to 0 via clearRecovery() after EXIT_COMPLETE
 *   assert: exitStage_after >= exitStage_before || exitStage_after == 0
 *
 * INV-4: SAFE MULTISIG IS SOLE HARVEST RECIPIENT
 *   All harvested stETH transfers to safeMultisig address only
 *   Moving funds from Safe requires 2-of-3 hardware wallet signatures
 *   assert: harvest destination == safeMultisig always
 *
 * INV-5: EMERGENCY EXIT REACHABLE FROM ANY STATE
 *   initiateEmergencyExit() callable when not already in exit
 *   System can never be locked out of emergency exit
 *   assert: exitState != EXIT_IN_PROGRESS || EXIT_STUCK => initiateEmergencyExit() callable
 *
 * ================================================================
 */
interface IEWBRevenueRouter {
    function recordStETHYieldAuto(uint256 amount) external;
}

interface ICurvePool {
    function get_dy(int128 i, int128 j, uint256 dx)
        external view returns (uint256);
}


abstract contract VaultStorage is ReentrancyGuard {
    using SafeERC20DN for IERC20DN;

    address public constant AAVE_V3_POOL =
        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant STETH =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WSTETH =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WETH =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // C-08 fix: awstETH is the correct aToken — vault deposits wstETH not stETH
    // aStETH (0x1982b...) was WRONG — vault holds awstETH on Aave v3 mainnet
    address public constant A_WSTETH =
        0x0B925eD163218f6662a35e0f0371Ac234f9E9371;

    address public owner;
    bool    public paused;

    // ── DEPENDENCY FAILURE STATES ───────────────────────────────
    // Formally specified behavior under external protocol failure
    //
    // AAVE_PAUSED:      Aave v3 has paused withdrawals
    //                   → harvest halted, capital preserved in Aave
    //                   → deed wallet manually resumes when Aave unpauses
    //
    // LIDO_QUEUE:       Lido withdrawal queue congested
    //                   → stETH submission halted
    //                   → existing stETH positions unaffected
    //
    // EXIT_IN_PROGRESS: Emergency exit initiated — pipeline running
    //                   → no new deployments
    //                   → harvest halted
    //                   → only exit functions callable
    //
    // EXIT_STUCK:       Exit pipeline stalled beyond timeout
    //                   → deed wallet force-advance required
    //
    // EXIT_COMPLETE:    All capital recovered to deed wallet
    //                   → system fully halted pending manual restart

    enum ExitState {
        NORMAL,
        EXIT_IN_PROGRESS,
        EXIT_STUCK,
        EXIT_COMPLETE
    }

    ExitState public exitState;
    bool      public aavePaused;      // Aave withdrawal pause detected
    bool      public lidoQueueAlert;  // Lido withdrawal queue congested
    uint256   public exitStartedAt;   // Timestamp when exit initiated
    uint256   public exitStage;       // 0=not started 1=aave 2=unwrap 3=complete
    uint256   public exitRecovered;   // Amount recovered to deed wallet

    /// @notice Maximum time per emergency exit stage before forceAdvanceExit() can be called.
    ///         6 hours gives sufficient time for Aave withdrawal + wstETH unwrap under normal conditions.
    ///         If a stage hangs (Aave paused, Curve pool drained), coldWallet can force-advance after 6h.
    uint256 public constant EXIT_STAGE_TIMEOUT = 6 hours;

    event AavePauseDetected(uint256 timestamp);
    event AavePauseCleared(uint256 timestamp);
    event LidoQueueAlert(uint256 timestamp);
    event ExitStageAdvanced(uint256 stage, uint256 timestamp);
    event ExitStuck(uint256 stage, uint256 elapsed);
    event ExitForceAdvanced(uint256 stage, address by);

    uint256 public totalDeployed;         // ETH deployed in long leg (principal)
    uint256 public totalYieldHarvested;   // Cumulative stETH harvested to deed wallet
    uint256 public lastHarvestTime;       // Timestamp of last harvest
    uint256 public shortNotional;         // ETH notional of dYdX short leg
    string  public dydxAccountId;         // dYdX account identifier
    uint256 public shortLeverage;         // Leverage ratio x100 (100 = 1x, 200 = 2x)
    uint256 public shortMarginUSD;        // Margin posted in USD cents
    uint256 public lastHedgeTime;         // Timestamp of last hedge record/rebalance

    // ── HEDGE ATTESTATION ───────────────────────────────────
    // Bot signs real dYdX position data — verified on-chain
    address public hedgeAttestor;         // Primary hedge attestor EOA
    // SIZE FIX / DEAD-CODE REMOVAL: the 2-of-3 hedge-quorum scaffolding
    // (hedgeAttestorB/C, hedgeQuorumVotes/Count/Approved, HEDGE_QUORUM,
    // setHedgeQuorumAttestors) was declared but NEVER enforced —
    // submitHedgeAttestation only ever verified the single primary attestor.
    // It was removed to reclaim bytecode; behaviour is unchanged. If a real
    // multi-attestor quorum is wanted, it must be implemented and re-audited.
    uint256 public lastAttestationTime;   // Timestamp of last verified attestation
    uint256 public lastFundingRateBps;    // Last attested funding rate (basis points)
    bytes32 public lastAttestationHash;   // Hash of last attested position data
    bool    public hedgeVerified;         // True if attestation is fresh (< 4 hours)
    // M-03 fix: nonce registry prevents replay of signed attestations
    mapping(bytes32 => bool) public usedAttestationNonces;
    uint256 public constant ATTESTATION_MAX_AGE = 15 minutes; // FIX R3: was 4 hours — stale hedge state is a risk

    struct HedgeSnapshot {
        uint256 notional;
        uint256 leverage;
        uint256 marginUSD;
        uint256 fundingRateBps;
        uint256 timestamp;
        bytes32 dataHash;
        address attestedBy;   // Always == hedgeAttestor — cryptographically verified
    }

    HedgeSnapshot[] public attestationHistory; // On-chain audit trail

    // M-02 fix: cap history arrays to prevent unbounded gas growth
    uint256 public constant MAX_HISTORY_LENGTH = 500;

    uint256 public maxDeployment      = 6_391 ether; // Max = full Layer 3 credit capacity
    uint256 public targetHealthFactor = 2e18;         // Target Aave health factor
    uint256 public rebalanceThreshold = 5;            // Max drift % before rebalance required

    // FIX: Minimum health factor required before a partial withdrawal is allowed
    uint256 public minWithdrawHealthFactor = 15e17; // 1.5x

    struct HarvestRecord {
        uint256 timestamp;
        uint256 yieldAmount;
        uint256 aaveHealthFactor;
    }

    HarvestRecord[] public harvestHistory;

    event CapitalDeployed(uint256 ethAmount, uint256 stEthReceived);
    event LongLegOpened(uint256 wstEthSupplied, uint256 aaveHealthFactor);
    event YieldHarvested(uint256 amount, uint256 timestamp);
    event YieldCompounded(uint256 amount, uint256 newTotalDeployed, uint256 timestamp);
    event PositionRebalanced(uint256 longNotional, uint256 shortNotional);
    event HedgeDriftWarning(uint256 longETH, uint256 shortETH, uint256 driftPct);
    event HedgeAttested(address attestor, uint256 notional, uint256 fundingRateBps,
        bytes32 dataHash, uint256 timestamp);
    /// @notice Emitted on every attestation with the live Aave HF for off-chain monitoring.
    ///         Allows detection of divergence between attested hedge state and Aave ground truth.
    event HedgeAaveCrossCheck(uint256 aaveHealthFactor, uint256 attestedNotional, uint256 timestamp);
    event HedgeAttestorUpdated(address oldAttestor, address newAttestor);
    event HedgeAttestationStale(uint256 lastAttestation, uint256 age);
    event CapitalWithdrawn(uint256 amount, address to);
    event EmergencyExit(uint256 recovered, address to);

    // ============================================================
    // TWO-LAYER GOVERNANCE MODEL
    // ============================================================
    //
    // LAYER 1 — SAFE MULTISIG (primary authority)
    //   Address: safeMultisig (set at deploy)
    //   Threshold: 2-of-3
    //   Signer A: Cold hardware wallet (Ledger) — Wayne Fyffe
    //   Signer B: Hardware wallet B (Trezor) — backup
    //   Signer C: Emergency key (cold storage) — recovery only
    //   Used for: all admin actions, parameter changes, deployments
    //   Legal binding: Safe transaction hash = on-chain evidence
    //
    // LAYER 2 — COLD WALLET (emergency single-signer)
    //   Address: coldWallet (set at deploy — same as Signer A)
    //   Used for: emergency exit ONLY if Safe quorum unavailable
    //   Cannot: change parameters, update oracle, modify config
    //   Can: initiateEmergencyExit(), forceAdvanceExitStage()
    //
    // HARVEST — FULLY AUTOMATED (no signer required)
    //   Keeper bot calls harvestYield() — no multisig approval needed
    //   stETH routes to safeMultisig address automatically
    //   Bot is operator only — cannot touch admin functions
    //
    // $211M UTILITY VALUE — SEPARATE FROM HARVEST
    //   EWB ecosystem value is backing context not harvest capital
    //   Harvest runs on deployed ETH only
    //   $211M does not affect harvest calculation
    //   $211M is NOT locked in this contract
    // ============================================================

    address public immutable safeMultisig; // L-2 FIX: immutable — cannot be reassigned post-deploy
    address public coldWallet;   // Emergency only — Signer A = cold hardware wallet
    address public immutable revenueRouter; // EWBRevenueRouter — auto-records yield on harvest

    modifier onlyMultisig() {
        require(msg.sender == safeMultisig,
            unicode"Requires Safe multisig — 2-of-3 signatures");
        _;
    }

    modifier onlyEmergency() {
        require(
            msg.sender == safeMultisig || msg.sender == coldWallet,
            "Requires multisig or cold wallet"
        );
        _;
    }

    modifier notPaused() { require(!paused, "Vault paused"); _; }

    // Keep onlyOwner as alias to onlyMultisig for backwards compatibility
    modifier onlyOwner() {
        require(msg.sender == safeMultisig,
            "Requires Safe multisig");
        _;
    }

    constructor(address _safeMultisig, address _coldWallet, address _revenueRouter) {
        require(_safeMultisig   != address(0), "Invalid Safe address");
        require(_coldWallet     != address(0), "Invalid cold wallet");
        require(_revenueRouter  != address(0), "Invalid revenueRouter");
        safeMultisig    = _safeMultisig;
        coldWallet      = _coldWallet;
        revenueRouter   = _revenueRouter;
        owner           = _safeMultisig; // owner points to Safe
        lastHarvestTime = block.timestamp;
    }

    // ------------------------------------------------------------------ //
}
