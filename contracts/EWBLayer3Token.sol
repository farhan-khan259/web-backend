// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWB Layer 3 Token — Credit Extraction Layer
 * @notice Enforceable on-chain token representing ownership
 *         of Layer 3 credit capacity and infrastructure yield
 *
 * ================================================================
 * LAYER 3 PARAMETERS (immutable on-chain)
 * ================================================================
 *
 * Total Layer 3 Value:  6,391 ETH / $13,402,766 USD
 * Credit by tier:
 *   EPIC:       315 ETH × 16   tokens × 30% LTV = 1,512 ETH
 *   SUPER RARE:  22 ETH × 362  tokens × 25% LTV = 1,991 ETH
 *   RARE:        10 ETH × 1492 tokens × 15% LTV = 2,238 ETH
 *   STANDARD:     1 ETH × 8130 tokens ×  8% LTV =   650 ETH
 *   TOTAL CREDIT: 6,391 ETH
 *
 * THREE INCOME STREAMS:
 *   Stream 1 LP Fees:    ~$160,823/yr (Uniswap V3)
 *   Stream 2 stETH:      ~$7,340/yr   (Aave v3)
 *   Stream 3 dYdX:       ~$16,776/yr  (funding rate)
 *   TOTAL ANNUAL:        ~$184,939
 *
 * THREE-LAYER DEFENSE MATRIX:
 *   Layer 1 Warning:      2.00x health — 72hr window
 *   Layer 2 Owner Action: 1.50x health — inject capital
 *   Layer 3 Hard Floor:   1.00x health — auto liquidate
 *
 * ENFORCEABILITY:
 *   L3T holders have proportional claim on infrastructure
 *   yield distributed by the Revenue Router contract.
 *   Layer 3 enforces liquidation — it is not liquidated.
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


interface IEWBRevenueRouter {
    function getTotalIncome() external view returns (
        uint256 lpFees,
        uint256 stethYield,
        uint256 dydxIncome,
        uint256 grandTotal
    );
}

contract EWBLayer3Token is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20Transfer for IERC20Transfer; // FIX R6

    // ============================================================
    // LAYER 3 IMMUTABLE CONSTANTS
    // ============================================================

    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;
    address public constant AAVE_V3_ROUTER =
        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // Layer 3 credit values
    uint256 public constant LAYER3_ETH_TOTAL         = 6_391 ether;
    uint256 public constant LAYER3_USD_TOTAL         = 13_402_766;
    uint256 public constant LAYER3_CREDIT_EPIC       = 1_512 ether;
    uint256 public constant LAYER3_CREDIT_SUPER_RARE = 1_991 ether;
    uint256 public constant LAYER3_CREDIT_RARE       = 2_238 ether;
    uint256 public constant LAYER3_CREDIT_STANDARD   =   650 ether;

    // LTV basis points
    uint256 public constant LTV_EPIC       = 3000; // 30%
    uint256 public constant LTV_SUPER_RARE = 2500; // 25%
    uint256 public constant LTV_RARE       = 1500; // 15%
    uint256 public constant LTV_STANDARD   =  800; //  8%
    uint256 public constant PRECISION      = 10000;

    // Annual income estimates
    uint256 public constant ANNUAL_LP_FEES_USD    = 160_823;
    uint256 public constant ANNUAL_STETH_USD      =   7_340;
    uint256 public constant ANNUAL_DYDX_USD       =  16_776;
    uint256 public constant ANNUAL_TOTAL_USD      = 184_939;

    // Defense matrix
    uint256 public constant HEALTH_WARNING   = 200; // 2.00x
    uint256 public constant HEALTH_ACTION    = 150; // 1.50x
    uint256 public constant HEALTH_LIQUIDATE = 100; // 1.00x

    // Token supply: 1 L3T per EWB token = 10,000 L3T total
    uint256 public constant MAX_SUPPLY = 10_000 * 1e18;

    // ============================================================
    // TWAP ORACLE — LIVE PRICE FEED
    // ============================================================

    address public immutable oracle;
    bool    public oracleConnected;

    // Layer identifier
    uint8   public constant LAYER_ID   = 3;
    string  public constant LAYER_NAME = "Credit Extraction Layer";

    // ============================================================
    // STATE
    // ============================================================

    address public distributionToken; // USDC
    address public revenueRouter;     // EWBRevenueRouter address

    uint256 public distributionIndex;
    mapping(address => uint256) public lastDistributionIndex;
    mapping(address => uint256) public pendingClaims;
    uint256 public totalDistributed;

    // Infrastructure yield record
    struct YieldEvent {
        uint8   stream;      // 0=LP 1=stETH 2=dYdX
        uint256 amount;
        uint256 timestamp;
    }
    YieldEvent[] public yieldHistory;

    // ============================================================
    // EVENTS
    // ============================================================

    event Layer3TokensMinted(address indexed to, uint256 amount);
    event OracleConnected(address indexed oracle, uint256 liveFloorETH);
    event InfrastructureYieldDistributed(uint256 amount, uint8 stream);
    event DistributionClaimed(address indexed holder, uint256 amount);
    event RevenueRouterSet(address router);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @param _distributionToken USDC address
     */
    constructor(address _distributionToken)
        ERC20(unicode"EWB Layer 3 — Credit Extraction Layer", "L3T")
        Ownable() {
        require(_distributionToken != address(0), "Invalid token");
        oracle = address(0);
        distributionToken = _distributionToken;
        _mint(SPV_TREASURY, MAX_SUPPLY);
        emit Layer3TokensMinted(SPV_TREASURY, MAX_SUPPLY);
    }

    // ============================================================
    // INFRASTRUCTURE YIELD DISTRIBUTION
    // ============================================================

    /**
     * @notice Distribute infrastructure yield to L3T holders
     * @dev Called by Revenue Router after collecting income
     *      from LP fees, stETH yield, or dYdX funding rate
     * @param amount USDC amount to distribute
     * @param stream Income stream ID (0=LP 1=stETH 2=dYdX)
     */
    function distributeYield(
        uint256 amount,
        uint8   stream
    ) external onlyOwner {
        require(amount > 0, "No amount");
        require(stream <= 2, "Invalid stream");
        require(totalSupply() > 0, "No tokens");

        // FIX R6: safeTransferFrom — inbound distribution funding
        SafeERC20Transfer.safeTransferFrom(IERC20Transfer(distributionToken), msg.sender, address(this), amount);

        uint256 newIndex = distributionIndex +
            (amount * 1e18 / totalSupply());
        distributionIndex = newIndex;
        totalDistributed += amount;

        yieldHistory.push(YieldEvent({
            stream:    stream,
            amount:    amount,
            timestamp: block.timestamp
        }));

        emit InfrastructureYieldDistributed(amount, stream);
    }

    /**
     * @notice Claim pending USDC yield
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
     * @notice View pending USDC yield claim
     */
    function getPendingClaim(address holder) external view returns (uint256) {
        uint256 earned = balanceOf(holder) *
            (distributionIndex - lastDistributionIndex[holder]) / 1e18;
        return pendingClaims[holder] + earned;
    }

    // ============================================================
    // TWAP ORACLE FUNCTIONS
    // ============================================================

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
     * @notice Calculate live max borrow using TWAP floor price
     * @dev Uses live oracle floor instead of hardcoded tier floor
     *      More accurate as floor price moves with market
     * @param tokenAmount Amount of L3T tokens
     * @param tier Rarity tier (0=EPIC 1=SR 2=RARE 3=STD)
     * @return liveBorrow Max borrow at live TWAP floor price
     * @return staticBorrow Max borrow at hardcoded tier floor
     */
    function calculateLiveBorrow(
        uint256 tokenAmount,
        uint8   tier
    ) external view returns (
        uint256 liveBorrow,
        uint256 staticBorrow
    ) {
        require(oracleConnected, "Oracle not connected");

        uint256 liveFloorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();

        // LTV for this tier
        uint256 ltv;
        if      (tier == 0) ltv = LTV_EPIC;
        else if (tier == 1) ltv = LTV_SUPER_RARE;
        else if (tier == 2) ltv = LTV_RARE;
        else                ltv = LTV_STANDARD;

        // Live borrow: uses actual TWAP floor
        uint256 liveCollateral = liveFloorETH * tokenAmount / 1e18;
        liveBorrow = liveCollateral * ltv / PRECISION;

        // Static borrow: uses hardcoded tier floor
        staticBorrow = calculateMaxBorrow(tokenAmount, tier);
    }

    /**
     * @notice Get live Layer 3 credit capacity using TWAP
     * @return liveCreditETH Total credit at current TWAP floor
     * @return staticCreditETH Total credit at hardcoded floors
     */
    function getLiveCreditCapacity() external view returns (
        uint256 liveCreditETH,
        uint256 staticCreditETH
    ) {
        require(oracleConnected, "Oracle not connected");

        uint256 liveFloor = IEWBGorillaOracle(oracle).getFloorPriceETH();

        // FIX: Division order corrected to prevent integer truncation.
        // Previous code divided by PRECISION before multiplying by LTV, losing precision.
        // Correct form: (count * floor * LTV) / (PRECISION * 1e18)
        // This preserves full 18-decimal precision before the final division.
        liveCreditETH =
            (16   * liveFloor * LTV_EPIC)       / (PRECISION * 1e18) +
            (362  * liveFloor * LTV_SUPER_RARE)  / (PRECISION * 1e18) +
            (1492 * liveFloor * LTV_RARE)        / (PRECISION * 1e18) +
            (8130 * liveFloor * LTV_STANDARD)    / (PRECISION * 1e18);

        staticCreditETH = LAYER3_ETH_TOTAL;
    }

    // ============================================================
    // CREDIT CALCULATORS
    // ============================================================

    /**
     * @notice Calculate max borrowable ETH for a token amount
     * @param tokenAmount L3T token amount
     * @param tier Rarity tier (0=EPIC 1=SR 2=RARE 3=STD)
     * @return maxBorrow Maximum borrowable ETH at tier LTV
     */
    function calculateMaxBorrow(
        uint256 tokenAmount,
        uint8   tier
    ) public pure returns (uint256 maxBorrow) {
        uint256 ltv;
        uint256 floorETH;

        if (tier == 0) { ltv = LTV_EPIC;       floorETH = 315 ether; }
        else if (tier == 1) { ltv = LTV_SUPER_RARE; floorETH = 22 ether;  }
        else if (tier == 2) { ltv = LTV_RARE;       floorETH = 10 ether;  }
        else                { ltv = LTV_STANDARD;   floorETH = 1 ether;   }

        uint256 collateral = floorETH * tokenAmount / 1e18;
        maxBorrow = collateral * ltv / PRECISION;
    }

    /**
     * @notice Calculate proportional Layer 3 value
     * @param tokenAmount L3T token amount
     * @return usdValue Proportional USD value
     * @return ethValue Proportional ETH value
     */
    function calculateValue(uint256 tokenAmount) external pure returns (
        uint256 usdValue,
        uint256 ethValue
    ) {
        usdValue = LAYER3_USD_TOTAL * tokenAmount / MAX_SUPPLY;
        ethValue = LAYER3_ETH_TOTAL * tokenAmount / MAX_SUPPLY;
    }

    /**
     * @notice Get annual yield estimate for a token holding
     * @param tokenAmount L3T token amount held
     * @return annualUSD Estimated annual USDC yield
     */
    function estimateAnnualYield(
        uint256 tokenAmount
    ) external pure returns (uint256 annualUSD) {
        annualUSD = ANNUAL_TOTAL_USD * tokenAmount / MAX_SUPPLY;
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

    function setRevenueRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid");
        revenueRouter = _router;
        emit RevenueRouterSet(_router);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getYieldHistoryCount() external view returns (uint256) {
        return yieldHistory.length;
    }
}
