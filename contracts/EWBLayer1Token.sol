// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWB Layer 1 Token — NFT Liquidation Layer
 * @notice Enforceable on-chain token representing ownership
 *         of Layer 1 value: raw NFT floor and physical asset
 *
 * ================================================================
 * LAYER 1 PARAMETERS (immutable on-chain)
 * ================================================================
 *
 * Total Layer 1 Value:  42,900 ETH / $89,961,300 USD
 * Physical FMV High:    $25,000,000 USD
 * Physical FMV Mid:     $17,500,000 USD
 * Physical FMV Low:     $10,000,000 USD
 * EWB Floor Price:      4.29 ETH per token
 * Total EWB Supply:     10,000 tokens
 *
 * TIER BID FLOORS:
 *   EPIC:       315 ETH — 16 tokens
 *   SUPER RARE:  22 ETH — 362 tokens
 *   RARE:        10 ETH — 1,492 tokens
 *   STANDARD:     1 ETH — 8,130 tokens
 *
 * ENFORCEABILITY:
 *   Holding L1T tokens represents a proportional claim on
 *   Layer 1 value distributions authorised by the owner.
 *   Liquidation of Layer 1 assets triggers pro-rata
 *   distribution to L1T holders via the distribution function.
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

// FIX: Standardised to OZ v5 import paths (/utils/ not /security/)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// FIX: IEWBGorillaOracle interface was used but never declared in this file
interface IEWBGorillaOracle {
    function getFloorPriceETH() external view returns (uint256);
    function getETHUSDPrice()   external view returns (uint256);
    function getFloorPriceUSD() external view returns (uint256);
    function useManualFloor()   external view returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}

contract EWBLayer1Token is ERC20, Ownable, ReentrancyGuard, Pausable {

    // ============================================================
    // LAYER 1 IMMUTABLE CONSTANTS
    // ============================================================

    // EWB NFT contract
    address public constant EWB_CONTRACT =
        0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4;

    // SPV Treasury
    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // Layer 1 valuation constants
    uint256 public constant LAYER1_ETH_TOTAL    = 42_900 ether;
    uint256 public constant LAYER1_USD_TOTAL    = 89_961_300;
    uint256 public constant PHYSICAL_FMV_LOW    = 10_000_000;
    uint256 public constant PHYSICAL_FMV_MID    = 17_500_000;
    uint256 public constant PHYSICAL_FMV_HIGH   = 25_000_000;
    uint256 public constant EWB_FLOOR_ETH       = 4.29 ether;
    uint256 public constant EWB_TOTAL_SUPPLY    = 10_000;

    // Tier bid floors
    uint256 public constant TIER_FLOOR_EPIC       = 315 ether;
    uint256 public constant TIER_FLOOR_SUPER_RARE =  22 ether;
    uint256 public constant TIER_FLOOR_RARE       =  10 ether;
    uint256 public constant TIER_FLOOR_STANDARD   =   1 ether;

    // Token supply: 1 L1T per EWB token = 10,000 L1T total
    uint256 public constant MAX_SUPPLY = 10_000 * 1e18;

    // ============================================================
    // TWAP ORACLE — LIVE PRICE FEED
    // ============================================================

    // EWBGorillaOracle address — set after deployment
    address public immutable oracle;
    bool    public oracleConnected;

    // Layer identifier
    uint8   public constant LAYER_ID = 1;
    string  public constant LAYER_NAME = "NFT Liquidation Layer";

    // ============================================================
    // STATE
    // ============================================================

    // Distribution tracking
    uint256 public totalDistributed;
    uint256 public distributionIndex; // accumulated ETH per token
    mapping(address => uint256) public lastDistributionIndex;
    mapping(address => uint256) public pendingClaims;

    // Enforcement record
    struct EnforcementEvent {
        uint256 timestamp;
        uint256 amount;
        string  reason;
        address enforcer;
    }
    EnforcementEvent[] public enforcementHistory;

    // ============================================================
    // EVENTS
    // ============================================================

    event Layer1TokensMinted(address indexed to, uint256 amount);
    event OracleConnected(address indexed oracle, uint256 liveFloorETH);
    event DistributionDeposited(uint256 amount, uint256 newIndex);
    event DistributionClaimed(address indexed holder, uint256 amount);
    event EnforcementRecorded(uint256 amount, string reason);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor() ERC20(unicode"EWB Layer 1 — NFT Liquidation Layer", "L1T")
        Ownable() {
        oracle = address(0);
        // Mint full supply to SPV Treasury — owner distributes
        _mint(SPV_TREASURY, MAX_SUPPLY);
        emit Layer1TokensMinted(SPV_TREASURY, MAX_SUPPLY);
    }

    // ============================================================
    // DISTRIBUTION — PRO-RATA TO L1T HOLDERS
    // ============================================================

    /**
     * @notice Deposit ETH for distribution to all L1T holders
     * @dev Called when Layer 1 liquidation proceeds are received
     *      or when owner distributes Layer 1 income
     */
    function depositDistribution() external payable onlyOwner {
        require(msg.value > 0, "No ETH sent");
        require(totalSupply() > 0, "No tokens");

        uint256 newIndex = distributionIndex +
            (msg.value * 1e18 / totalSupply());
        distributionIndex = newIndex;
        totalDistributed  += msg.value;

        emit DistributionDeposited(msg.value, newIndex);
    }

    /**
     * @notice Claim pending ETH distribution
     */
    function claimDistribution() external nonReentrant whenNotPaused {
        _updatePending(msg.sender);
        uint256 pending = pendingClaims[msg.sender];
        require(pending > 0, "Nothing to claim");

        pendingClaims[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: pending}("");
        require(success, "Claim transfer failed");

        emit DistributionClaimed(msg.sender, pending);
    }

    /**
     * @notice View pending claim for an address
     */
    function getPendingClaim(address holder) external view returns (uint256) {
        uint256 earned = balanceOf(holder) *
            (distributionIndex - lastDistributionIndex[holder]) / 1e18;
        return pendingClaims[holder] + earned;
    }

    // ============================================================
    // ENFORCEMENT RECORD
    // ============================================================

    /**
     * @notice Record a Layer 1 enforcement event on-chain
     * @dev Called when liquidation or distribution occurs
     *      Creates immutable audit trail of Layer 1 enforcement
     */
    function recordEnforcement(
        uint256 amount,
        string calldata reason
    ) external onlyOwner {
        enforcementHistory.push(EnforcementEvent({
            timestamp: block.timestamp,
            amount:    amount,
            reason:    reason,
            enforcer:  msg.sender
        }));
        emit EnforcementRecorded(amount, reason);
    }

    // ============================================================
    // LAYER 1 VALUE CALCULATOR
    // ============================================================

    /**
     * @notice Connect the TWAP oracle
     * @dev Called after EWBGorillaOracle is deployed
     * @param _oracle EWBGorillaOracle contract address
     */
    // oracle is immutable — set in constructor only

    /**
     * @notice Get live floor price from TWAP oracle
     * @return floorETH  Current floor in ETH (18 decimals)
     * @return floorUSD  Current floor in USD (6 decimals)
     * @return isManual  True if manual floor active, false if TWAP
     */
    function getLiveFloor() external view returns (
        uint256 floorETH,
        uint256 floorUSD,
        bool    isManual
    ) {
        require(oracleConnected, "Oracle not connected");
        floorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();
        floorUSD = IEWBGorillaOracle(oracle).getFloorPriceUSD();
        isManual = IEWBGorillaOracle(oracle).useManualFloor();
    }

    /**
     * @notice Calculate Layer 1 value using LIVE TWAP price
     * @param tokenAmount Amount of L1T tokens
     * @return liveUSD  Live USD value (scales with TWAP floor)
     * @return liveETH  Live ETH value (scales with TWAP floor)
     * @return staticUSD Static USD value (from constants)
     */
    function calculateLiveValue(uint256 tokenAmount) external view returns (
        uint256 liveUSD,
        uint256 liveETH,
        uint256 staticUSD
    ) {
        require(oracleConnected, unicode"Oracle not connected — use calculateValue()");

        // Static value from hardcoded constants
        staticUSD = LAYER1_USD_TOTAL * tokenAmount / MAX_SUPPLY;

        // Live value from TWAP oracle
        uint256 floorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();
        uint256 ethUSD   = IEWBGorillaOracle(oracle).getETHUSDPrice();

        // Live ETH value: proportional share of total ETH floor
        // Total ETH floor = 10,000 tokens * current floor per token
        uint256 totalLiveETH = floorETH * EWB_TOTAL_SUPPLY;
        liveETH  = totalLiveETH * tokenAmount / MAX_SUPPLY;

        // Live USD value: liveETH * ethUSD / 1e20 (18dec * 8dec -> 6dec)
        liveUSD  = liveETH * ethUSD / 1e20;
    }

    /**
     * @notice Calculate Layer 1 value represented by a token amount
     * @dev Uses static constants — use calculateLiveValue() for TWAP
     * @param tokenAmount Amount of L1T tokens
     * @return usdValue Proportional USD value
     * @return ethValue Proportional ETH value
     */
    function calculateValue(uint256 tokenAmount) external pure returns (
        uint256 usdValue,
        uint256 ethValue
    ) {
        usdValue = LAYER1_USD_TOTAL * tokenAmount / MAX_SUPPLY;
        ethValue = LAYER1_ETH_TOTAL * tokenAmount / MAX_SUPPLY;
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    function _updatePending(address holder) internal {
        uint256 earned = balanceOf(holder) *
            (distributionIndex - lastDistributionIndex[holder]) / 1e18;
        pendingClaims[holder]          += earned;
        lastDistributionIndex[holder]   = distributionIndex;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal virtual override {
        if (from != address(0)) _updatePending(from);
        if (to   != address(0)) _updatePending(to);
        super._beforeTokenTransfer(from, to, amount);
    }

    // ============================================================
    // ADMIN
    // ============================================================

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function getEnforcementCount() external view returns (uint256) {
        return enforcementHistory.length;
    }

    receive() external payable {}
}
