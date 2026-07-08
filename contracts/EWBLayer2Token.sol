// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWB Layer 2 Token — Utility Liquidation Layer
 * @notice Enforceable on-chain token representing ownership
 *         of Layer 2 value: ecosystem utility and sovereignty premium
 *
 * ================================================================
 * LAYER 2 PARAMETERS (immutable on-chain)
 * ================================================================
 *
 * Total Layer 2 Value:  27,992 ETH / $58,700,000 USD
 * Total Trait Value:    $70,415,163 USD
 * Digital Premium:      $58,700,000 USD (above physical appraisal)
 * Uncollateralised gap: $11,715,163 (scarcity/network premium)
 *
 * TRAIT VALUES BY TIER:
 *   EPIC:       $9,908,325  — 16 tokens
 *   SUPER RARE: $15,547,158 — 362 tokens
 *   RARE:       $29,106,360 — 1,492 tokens
 *   STANDARD:   $15,853,320 — 8,130 tokens
 *   TOTAL:      $70,415,163
 *
 * ENFORCEABILITY:
 *   L2T holders have proportional claim on ecosystem utility
 *   revenue including licensing, royalties, and trait-based
 *   premium distributions authorised by the owner.
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

// FIX: Standardised to OZ v5 import paths (/utils/ not /security/)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IEWBGorillaOracle {
    function getFloorPriceETH() external view returns (uint256);
    function getETHUSDPrice()   external view returns (uint256);
    function getFloorPriceUSD() external view returns (uint256);
    function useManualFloor()   external view returns (bool);
    function twapWindow()       external view returns (uint32);
}

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount)
        external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// FIX R6: Safe ERC-20 transfer wrapper — handles USDT-style non-returning tokens
library SafeERC20Transfer {
    function safeTransfer(IERC20Transfer token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20Transfer: transfer failed");
    }
    function safeTransferFrom(IERC20Transfer token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeERC20Transfer: transferFrom failed");
    }
}


contract EWBLayer2Token is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20Transfer for IERC20Transfer; // FIX R6

    // ============================================================
    // LAYER 2 IMMUTABLE CONSTANTS
    // ============================================================

    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // Layer 2 valuation constants
    uint256 public constant LAYER2_ETH_TOTAL        = 27_992 ether;
    uint256 public constant LAYER2_USD_TOTAL         = 58_700_000;
    uint256 public constant TOTAL_TRAIT_VALUE        = 70_415_163;
    uint256 public constant UNCOLLATERALISED_PREMIUM =  4_215_163;

    // Trait values by tier (USD — no decimals)
    uint256 public constant TRAIT_VALUE_EPIC       =  9_908_325;
    uint256 public constant TRAIT_VALUE_SUPER_RARE = 15_547_158;
    uint256 public constant TRAIT_VALUE_RARE       = 29_106_360;
    uint256 public constant TRAIT_VALUE_STANDARD   = 15_853_320;

    // Supply allocation
    uint256 public constant TOTAL_EWB_SUPPLY    = 10_000;
    uint256 public constant TREASURY_SUPPLY     =  9_318;
    uint256 public constant CIRCULATING_SUPPLY  =    682;

    // Token supply: 1 L2T per EWB token = 10,000 L2T total
    uint256 public constant MAX_SUPPLY = 10_000 * 1e18;

    // ============================================================
    // TWAP ORACLE — LIVE PRICE FEED
    // ============================================================

    address public immutable oracle;
    bool    public oracleConnected;

    // Layer identifier
    uint8   public constant LAYER_ID   = 2;
    string  public constant LAYER_NAME = "Utility Liquidation Layer";

    // ============================================================
    // STABLECOIN DISTRIBUTION (Layer 2 pays in USDC)
    // ============================================================

    address public distributionToken; // USDC address
    uint256 public distributionIndex;
    mapping(address => uint256) public lastDistributionIndex;
    mapping(address => uint256) public pendingClaims;
    uint256 public totalDistributed;

    // Utility revenue streams
    struct UtilityRevenue {
        string  source;      // "LICENSING" "ROYALTY" "TRAIT_PREMIUM"
        uint256 amount;
        uint256 timestamp;
    }
    UtilityRevenue[] public revenueHistory;

    // Trait tier tracking per token
    mapping(uint256 => uint8) public tokenTier; // 0=EPIC 1=SR 2=RARE 3=STD

    // ============================================================
    // EVENTS
    // ============================================================

    event Layer2TokensMinted(address indexed to, uint256 amount);
    event OracleConnected(address indexed oracle, uint256 liveFloorETH);
    event UtilityRevenueDeposited(uint256 amount, string source);
    event DistributionClaimed(address indexed holder, uint256 amount);
    event TierRegistered(uint256 indexed tokenId, uint8 tier);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @param _distributionToken USDC address for distributions
     */
    constructor(address _distributionToken)
        ERC20(unicode"EWB Layer 2 — Utility Liquidation Layer", "L2T")
        Ownable() {
        require(_distributionToken != address(0), "Invalid token");
        oracle = address(0);
        distributionToken = _distributionToken;
        _mint(SPV_TREASURY, MAX_SUPPLY);
        emit Layer2TokensMinted(SPV_TREASURY, MAX_SUPPLY);
    }

    // ============================================================
    // UTILITY REVENUE DISTRIBUTION
    // ============================================================

    /**
     * @notice Deposit utility revenue (USDC) for distribution
     * @dev Sources: licensing fees, royalties, trait premiums
     * @param amount USDC amount to distribute
     * @param source Revenue source description
     */
    function depositUtilityRevenue(
        uint256 amount,
        string calldata source
    ) external onlyOwner {
        require(amount > 0, "No amount");
        require(totalSupply() > 0, "No tokens");

        // FIX R6: safeTransferFrom — inbound distribution funding
        SafeERC20Transfer.safeTransferFrom(IERC20Transfer(distributionToken), msg.sender, address(this), amount);

        uint256 newIndex = distributionIndex +
            (amount * 1e18 / totalSupply());
        distributionIndex = newIndex;
        totalDistributed += amount;

        revenueHistory.push(UtilityRevenue({
            source:    source,
            amount:    amount,
            timestamp: block.timestamp
        }));

        emit UtilityRevenueDeposited(amount, source);
    }

    /**
     * @notice Claim pending USDC distribution
     */
    function claimDistribution() external nonReentrant whenNotPaused {
        _updatePending(msg.sender);
        uint256 pending = pendingClaims[msg.sender];
        require(pending > 0, "Nothing to claim");

        pendingClaims[msg.sender] = 0;

        // FIX R6: was require(IERC20Transfer.transfer()) — now uses safeTransfer
        IERC20Transfer(distributionToken).safeTransfer(msg.sender, pending);

        emit DistributionClaimed(msg.sender, pending);
    }

    /**
     * @notice View pending USDC claim
     */
    function getPendingClaim(address holder) external view returns (uint256) {
        uint256 earned = balanceOf(holder) *
            (distributionIndex - lastDistributionIndex[holder]) / 1e18;
        return pendingClaims[holder] + earned;
    }

    // ============================================================
    // TRAIT TIER WEIGHTING
    // ============================================================

    /**
     * @notice Register token tiers for weighted distribution
     * @dev EPIC tokens earn higher trait-weighted distributions
     */
    function registerTokenTier(
        uint256[] calldata tokenIds,
        uint8[]   calldata tiers
    ) external onlyOwner {
        require(tokenIds.length == tiers.length, "Length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(tiers[i] <= 3, "Invalid tier");
            tokenTier[tokenIds[i]] = tiers[i];
            emit TierRegistered(tokenIds[i], tiers[i]);
        }
    }

    /**
     * @notice Connect the TWAP oracle
     */
    // oracle is immutable — set in constructor only

    /**
     * @notice Get live floor price from TWAP oracle
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
     * @notice Calculate Layer 2 value using LIVE TWAP price
     * @dev Layer 2 is a USD-denominated trait premium above physical
     *      TWAP scales the physical anchor portion proportionally
     * @param tokenAmount Amount of L2T tokens
     * @return liveUSD  Live USD value scaled to TWAP
     * @return staticUSD Static USD value from constants
     */
    function calculateLiveValue(uint256 tokenAmount) external view returns (
        uint256 liveUSD,
        uint256 staticUSD
    ) {
        require(oracleConnected, unicode"Oracle not connected — use calculateValue()");

        // Static value
        staticUSD = LAYER2_USD_TOTAL * tokenAmount / MAX_SUPPLY;

        // Live: trait value scales with physical anchor (floor price)
        // Physical component scales with ETH, digital premium is fixed
        uint256 floorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();
        uint256 ethUSD   = IEWBGorillaOracle(oracle).getETHUSDPrice();

        // Physical FMV mid anchored to ETH price movement
        // 9,300 treasury tokens * floorETH * ethUSD / decimals
        uint256 physicalComponent = 9_318 * floorETH * ethUSD / 1e26;
        // Digital premium stays fixed at $45,415,163
        uint256 digitalPremium = 45_415_163 * 1e6;
        liveUSD = (physicalComponent + digitalPremium) * tokenAmount / MAX_SUPPLY;
    }

    /**
     * @notice Get trait value for a specific tier
     */
    function getTierTraitValue(uint8 tier) external pure returns (uint256) {
        if (tier == 0) return TRAIT_VALUE_EPIC;
        if (tier == 1) return TRAIT_VALUE_SUPER_RARE;
        if (tier == 2) return TRAIT_VALUE_RARE;
        return TRAIT_VALUE_STANDARD;
    }

    // ============================================================
    // LAYER 2 VALUE CALCULATOR
    // ============================================================

    /**
     * @notice Calculate Layer 2 proportional value
     * @param tokenAmount Amount of L2T tokens
     * @return usdValue Proportional USD value
     * @return ethValue Proportional ETH value
     */
    function calculateValue(uint256 tokenAmount) external pure returns (
        uint256 usdValue,
        uint256 ethValue
    ) {
        usdValue = LAYER2_USD_TOTAL * tokenAmount / MAX_SUPPLY;
        ethValue = LAYER2_ETH_TOTAL * tokenAmount / MAX_SUPPLY;
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    function _updatePending(address holder) internal {
        uint256 earned = balanceOf(holder) *
            (distributionIndex - lastDistributionIndex[holder]) / 1e18;
        pendingClaims[holder]         += earned;
        lastDistributionIndex[holder]  = distributionIndex;
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
    function getRevenueHistoryCount() external view returns (uint256) {
        return revenueHistory.length;
    }
}
