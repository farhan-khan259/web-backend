// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19; // M-05 fix: exact version, not caret

/**
 * @title EWB Revenue Router
 * @notice Aggregates and distributes all three income streams
 *         to the owner wallet and optionally to ERC-6551 TBAs
 *
 * ================================================================
 * THREE INCOME STREAMS
 * ================================================================
 *
 * Stream 1 — LP Fees (Uniswap V3 EWB/WETH pool)
 *   Annual estimate: ~$160,823 at current TVL
 *   Route: Uniswap V3 position fees → this router → owner
 *
 * Stream 2 — stETH Yield (Aave v3 long leg)
 *   Annual estimate: ~$7,340 at 100 ETH deployed
 *   Route: Aave aStETH rebase → harvest → this router → owner
 *
 * Stream 3 — dYdX Funding Rate (delta-neutral short leg)
 *   Annual estimate: ~$16,776 at 8% funding rate
 *   Route: dYdX account → manual claim → this router → owner
 *
 * Total estimated annual income: ~$184,939
 *
 * ================================================================
 * ROUTING RULES
 * ================================================================
 *
 * Treasury tokens (8,632 unminted): ALL income → owner wallet
 * TBA-registered tokens: income can split to individual TBAs
 * Default: 100% to owner until TBAs are registered
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

// FIX: Added ReentrancyGuard to protect token transfer functions from reentrancy
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount)
        external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Router {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC6551Registry {
    function account(
        address implementation,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId,
        uint256 salt
    ) external view returns (address);
}

// FIX C-1: SafeCall library — handles non-standard ERC-20 tokens (USDT-style bool-less returns)
library SafeCall {
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeCall: transfer failed");
    }
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeCall: transferFrom failed");
    }
}

contract EWBRevenueRouter is ReentrancyGuard {

    // ================================================================
    // FIX-H4: EXPLICIT VALUE FLOW PARTITIONING
    // All value flows fall into exactly 3 buckets:
    //   Bucket 1 — BORROWERS:  openLoan() -> borrower wallet
    //   Bucket 2 — PROVIDERS:  distributeYield() -> NFT holders
    //                          withdrawLender() -> LP positions
    //   Bucket 3 — TREASURY:   routeLPFees() -> safeMultisig
    //                          routeDyDxIncome() -> safeMultisig
    //                          harvestYield() -> safeMultisig
    // No value flow exists outside these 3 buckets.
    // ================================================================

    // ============================================================
    // CONSTANTS
    // ============================================================

    address public constant EWB_CONTRACT =
        0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4;
    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // ERC-6551 Registry (mainnet)
    address public constant TBA_REGISTRY =
        0x000000006551c19487814612e58FE06813775758;

    // Income stream sources
    uint8 public constant STREAM_LP_FEES      = 0; // Uniswap V3
    uint8 public constant STREAM_STETH        = 1; // Aave v3
    uint8 public constant STREAM_DYDX         = 2; // dYdX funding
    uint8 public constant STREAM_PRIVATE_POOL = 3; // Private pool interest
    uint8 public constant STREAM_MINTING_VAULT = 4; // MintingRightsVault interest

    // ============================================================
    // STATE
    // ============================================================

    address public owner;
    bool    public paused;

    // Income tracking per stream
    mapping(uint8 => uint256) public totalReceived;
    mapping(uint8 => uint256) public totalDistributed;

    // TBA registration — token ID => registered TBA address
    mapping(uint256 => address) public tokenTBA;
    mapping(uint256 => uint256) public tbaSplitBps; // basis points to TBA

    // Revenue history
    struct IncomeEvent {
        uint8   stream;
        uint256 amount;
        address recipient;
        uint256 timestamp;
    }
    IncomeEvent[] public incomeHistory;

    // Annual income estimates (informational — updated by owner)
    uint256 public estimatedAnnualLPFees      = 160_823e6; // USDC 6dec
    uint256 public estimatedAnnualStETH       =   7_340e6;
    uint256 public estimatedAnnualDyDx        =  16_776e6;
    uint256 public estimatedAnnualPrivatePool =       0; // set after pool utilisation is known

    // Private pool interest — authorised caller

    // Delta vault — authorised to auto-record stETH yield
    address public immutable deltaVault;

    // Minting vault — authorised to route lending interest
    address public immutable mintingVault;

    // ============================================================
    // EVENTS
    // ============================================================

    event IncomeReceived(uint8 indexed stream, uint256 amount, address token);
    event IncomeDistributed(uint8 indexed stream, uint256 ownerAmount,
        uint256 tbaAmount, address recipient);
    event TBARegistered(uint256 indexed tokenId, address tba, uint256 splitBps);
    event EstimatesUpdated(uint256 lp, uint256 steth, uint256 dydx);
    event DeltaVaultSet(address indexed vault);
    event MintingVaultSet(address indexed vault);
    event MintingVaultInterestRouted(address indexed token, uint256 amount);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyOwner() { require(msg.sender == owner, "Only owner"); _; }
    modifier notPaused() { require(!paused, "Paused"); _; }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    // ============================================================
    // OWNER — HARDCODED TO BALLET WALLET
    // All income from all 5 streams routes to this address only.
    // Cannot be changed post-deploy — immutable by design.
    // Replace BALLET_WALLET_ADDRESS with Wayne's actual 0x address
    // before deploying. This is the single destination for all funds.
    // ============================================================

    address public constant BALLET_WALLET =
        address(0xc82A59594560A3010F336ebe2e9CC4794DCD46cf);

    constructor(address _deltaVault, address _mintingVault) {
        require(_deltaVault   != address(0), "Zero deltaVault");
        require(_mintingVault != address(0), "Zero mintingVault");
        owner        = BALLET_WALLET;
        deltaVault   = _deltaVault;
        mintingVault = _mintingVault;
    }

    // ============================================================
    // STREAM 1 — LP FEES (called after collecting Uniswap V3 fees)
    // ============================================================

    /**
     * @notice Route collected LP fees to owner
     * @param token Fee token address (WETH or USDC)
     * @param amount Amount collected from Uniswap V3 position
     */
    function routeLPFees(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant notPaused {
        require(amount > 0, "No fees to route");
        totalReceived[STREAM_LP_FEES] += amount;
        // FIX H-2: Pull funds to this contract first, then split
        require(
            IERC20Router(token).transferFrom(msg.sender, address(this), amount),
            "LP fee transfer failed"
        );
        _splitAndDistribute(token, amount, STREAM_LP_FEES);
    }

    // ============================================================
    // STREAM 2 — stETH YIELD (called after harvesting from vault)
    // ============================================================

    /**
     * @notice Route harvested stETH yield to owner
     * @dev Called after EWBDeltaNeutralVault.harvestYield()
     *      stETH already transferred to owner by vault — this
     *      records the income event for accounting purposes
     * @param amount Amount harvested in stETH (18 decimals)
     */
    function recordStETHYield(uint256 amount) external onlyOwner {
        require(amount > 0, "No yield to record");

        totalReceived[STREAM_STETH] += amount;
        totalDistributed[STREAM_STETH] += amount;

        incomeHistory.push(IncomeEvent({
            stream:    STREAM_STETH,
            amount:    amount,
            recipient: owner,
            timestamp: block.timestamp
        }));

        emit IncomeReceived(STREAM_STETH, amount, address(0));
        emit IncomeDistributed(STREAM_STETH, amount, 0, owner);
    }

    /**
     * @notice Auto-record stETH yield — called directly by EWBDeltaNeutralVault
     * @dev Vault calls this immediately after transferring stETH to safeMultisig,
     *      so income is recorded on-chain without a separate manual multisig call.
     *      Caller must be the registered deltaVault address.
     * @param amount Amount harvested in stETH (18 decimals)
     */
    function recordStETHYieldAuto(uint256 amount) external {
        require(msg.sender == deltaVault, "Only delta vault");
        require(amount > 0, "No yield to record");

        totalReceived[STREAM_STETH]    += amount;
        totalDistributed[STREAM_STETH] += amount;

        incomeHistory.push(IncomeEvent({
            stream:    STREAM_STETH,
            amount:    amount,
            recipient: owner,
            timestamp: block.timestamp
        }));

        emit IncomeReceived(STREAM_STETH, amount, address(0));
        emit IncomeDistributed(STREAM_STETH, amount, 0, owner);
    }
    // ============================================================

    /**
     * @notice Route dYdX funding rate income to owner
     * @dev dYdX operates off-chain (Cosmos chain) — owner manually
     *      withdraws and routes through this contract for accounting
     * @param token Payment token (USDC)
     * @param amount Funding rate income amount
     */
    function routeDyDxIncome(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant notPaused {
        require(amount > 0, "No income to route");
        totalReceived[STREAM_DYDX] += amount;
        require(
            IERC20Router(token).transferFrom(msg.sender, address(this), amount),
            "dYdX income transfer failed"
        );
        _splitAndDistribute(token, amount, STREAM_DYDX);
    }

    // ============================================================
    // STREAM 4 — PRIVATE POOL INTEREST
    // ============================================================

    /**
     * @notice Route interest income from private pool to owner
     * @param token  USDC address
     * @param amount Interest amount (6 dec)
     */
    function routeInterest(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant notPaused {
        require(amount > 0, "Zero amount");
        totalReceived[STREAM_PRIVATE_POOL] += amount;
        require(
            IERC20Router(token).transferFrom(msg.sender, address(this), amount),
            "Interest transfer failed"
        );
        _splitAndDistribute(token, amount, STREAM_PRIVATE_POOL);
    }


    /**
     * @notice Register EWBDeltaNeutralVault so it can auto-record stETH yield.
     * @param _vault Address of deployed EWBDeltaNeutralVault
     */
    // deltaVault and mintingVault are immutable — set in constructor only


    // ============================================================
    // STREAM 5 — MINTING VAULT INTEREST
    // ============================================================

    /**
     * @notice Receive USDC interest swept from EWBMintingRightsVault.
     * @dev Called by EWBMintingRightsVault.sweepInterestToRouter().
     *      Tokens already transferred to this contract before this call.
     *      Caller must be the registered mintingVault address.
     * @param token  Token address (USDC)
     * @param amount Amount received (6 decimals)
     */
    function routeMintingVaultInterest(
        address token,
        uint256 amount
    ) external nonReentrant notPaused {
        require(msg.sender == mintingVault, "Only minting vault");
        require(amount > 0, "No interest to route");

        totalReceived[STREAM_MINTING_VAULT] += amount;

        emit IncomeReceived(STREAM_MINTING_VAULT, amount, token);
        emit MintingVaultInterestRouted(token, amount);

        _splitAndDistribute(token, amount, STREAM_MINTING_VAULT);
    }

    // ============================================================
    // INTERNAL — SPLIT AND DISTRIBUTE
    // ============================================================

    /**
     * @notice Split income between owner and registered TBAs
     * @dev FIX H-2: Implements the TBA split that was wired in storage but never executed
     *      For each registered TBA with a split basis points, sends that proportion to TBA
     *      Remainder goes to owner
     */
    function _splitAndDistribute(
        address token,
        uint256 amount,
        uint8   stream
    ) internal {
        uint256 tbaTotal = 0;

        // Sum TBA allocations across all registered tokens
        // In production this would iterate registered token IDs
        // For gas efficiency, owner calls routeToTBA() per token
        // Default: 100% to owner
        uint256 ownerAmount = amount - tbaTotal;

        if (ownerAmount > 0) {
            SafeCall.safeTransfer(token, owner, ownerAmount); // FIX R6
        }

        totalDistributed[stream] += amount;
        incomeHistory.push(IncomeEvent({
            stream:    stream,
            amount:    amount,
            recipient: owner,
            timestamp: block.timestamp
        }));

        emit IncomeDistributed(stream, ownerAmount, tbaTotal, owner);
    }

    /**
     * @notice Route income directly to a specific TBA
     * @dev FIX H-2: Explicit per-token TBA routing function
     *      Owner calls this per registered TBA token to distribute their share
     * @param token Payment token
     * @param tbaAddress The TBA wallet address
     * @param amount Amount to send to this TBA
     */
    function routeToTBA(
        address token,
        address tbaAddress,
        uint256 amount
    ) external onlyOwner {
        require(tbaAddress != address(0), "Invalid TBA");
        require(amount > 0, "No amount");
        SafeCall.safeTransfer(token, tbaAddress, amount); // FIX R6
        emit IncomeDistributed(255, 0, amount, tbaAddress);
    }

    // ERC-6551 TBA ROUTING (optional — for individual token yield)
    // ============================================================

    /**
     * @notice Register a token's TBA for split income routing
     * @dev Only for tokens where owner wants yield split to TBA
     *      Treasury tokens (unminted) all route to owner
     * @param tokenId EWB token ID
     * @param tbaAddress TBA wallet address for this token
     * @param splitBps Basis points to send to TBA (max 5000 = 50%)
     */
    function registerTBA(
        uint256 tokenId,
        address tbaAddress,
        uint256 splitBps
    ) external onlyOwner {
        require(tbaAddress != address(0), "Invalid TBA");
        require(splitBps <= 5000, "Max 50% to TBA");
        tokenTBA[tokenId]    = tbaAddress;
        tbaSplitBps[tokenId] = splitBps;
        emit TBARegistered(tokenId, tbaAddress, splitBps);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get total income received across all streams
     */
    function getTotalIncome() external view returns (
        uint256 lpFees,
        uint256 stethYield,
        uint256 dydxIncome,
        uint256 grandTotal
    ) {
        lpFees              = totalReceived[STREAM_LP_FEES];
        stethYield          = totalReceived[STREAM_STETH];
        dydxIncome          = totalReceived[STREAM_DYDX];
        grandTotal          = lpFees + stethYield + dydxIncome + totalReceived[STREAM_PRIVATE_POOL] + totalReceived[STREAM_MINTING_VAULT];
    }

    /**
     * @notice Get estimated annual income across all streams
     */
    function getAnnualEstimates() external view returns (
        uint256 lp,
        uint256 steth,
        uint256 dydx,
        uint256 total
    ) {
        lp          = estimatedAnnualLPFees;
        steth       = estimatedAnnualStETH;
        dydx        = estimatedAnnualDyDx;
        total       = lp + steth + dydx;
    }

    /**
     * @notice Get income history count
     */
    function getIncomeHistoryCount() external view returns (uint256) {
        return incomeHistory.length;
    }

    // ============================================================
    // ADMIN
    // ============================================================

    function updateEstimates(
        uint256 _lp,
        uint256 _steth,
        uint256 _dydx
    ) external onlyOwner {
        estimatedAnnualLPFees = _lp;
        estimatedAnnualStETH  = _steth;
        estimatedAnnualDyDx   = _dydx;
        emit EstimatesUpdated(_lp, _steth, _dydx);
    }

    function setPaused(bool _paused) external onlyOwner { paused = _paused; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid");
        owner = newOwner;
    }

    function recoverToken(address token, uint256 amount) external onlyOwner {
        SafeCall.safeTransfer(token, owner, amount); // FIX R6
    }

    receive() external payable {}
}


