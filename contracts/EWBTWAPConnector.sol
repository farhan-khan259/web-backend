// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWB TWAP Connector
 * @notice Bridges EWBGorillaOracle TWAP price feed to all
 *         three layer tokens and the whale vault
 *
 * ================================================================
 * WHAT THIS CONTRACT DOES
 * ================================================================
 *
 * The TWAP (Time Weighted Average Price) is the manipulation-
 * resistant price feed that the entire EWB ecosystem relies on.
 *
 * This connector:
 *   1. Reads live floor price from EWBGorillaOracle (TWAP or manual)
 *   2. Calculates real-time USD values for all three layers
 *   3. Provides health factor readings for active positions
 *   4. Updates layer token value estimates when price moves
 *   5. Triggers alerts if floor drops toward liquidation thresholds
 *
 * ================================================================
 * TWAP PARAMETERS
 * ================================================================
 *
 * Source:        EWBGorillaOracle._getTWAPPrice()
 * Window:        30 days (manipulation resistant)
 * Minimum:       1 hour (configurable down to 1hr)
 * Fallback:      Manual floor (owner set, 7 day max age)
 * Chainlink:     ETH/USD feed 0x5f4eC3...b8419
 *
 * ================================================================
 * FLOOR DROP ALERT THRESHOLDS
 * ================================================================
 *
 * Current floor:  4.29 ETH
 * Layer 1 Warn:   floor drops 15-25% → 3.22–3.65 ETH
 * Layer 2 Action: floor drops 25-45% → 2.36–3.22 ETH
 * Layer 3 Hard:   floor drops 45%+   → below 2.36 ETH
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

interface IEWBGorillaOracle {
    function getFloorPriceETH() external view returns (uint256);
    function getETHUSDPrice()   external view returns (uint256);
    function getFloorPriceUSD() external view returns (uint256);
    function useManualFloor()   external view returns (bool);
    function twapWindow()       external view returns (uint32);
    function manualFloorSetAt() external view returns (uint256);
    function manualFloorMaxAge()external view returns (uint256);
}

interface IEWBLayerToken {
    function LAYER_ID()          external view returns (uint8);
    function calculateValue(uint256 tokenAmount) external view returns (
        uint256 usdValue, uint256 ethValue);
}

contract EWBTWAPConnector {

    // ============================================================
    // CONSTANTS
    // ============================================================

    // Protocol addresses
    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // Layer stack totals (ETH 18 decimals)
    uint256 public constant TOTAL_SUPPLY        = 10_000;
    uint256 public constant STACK_L1_ETH        = 42_900 ether;
    uint256 public constant STACK_L2_ETH        = 27_992 ether;
    uint256 public constant STACK_L3_ETH        =  6_391 ether;
    uint256 public constant STACK_COMBINED_ETH  = 77_283 ether;

    // Health factor thresholds (x100 — matches EWBWhaleVault)
    uint256 public constant HEALTH_WARNING   = 200; // 2.00x
    uint256 public constant HEALTH_ACTION    = 150; // 1.50x
    uint256 public constant HEALTH_LIQUIDATE = 100; // 1.00x

    // Floor drop thresholds (basis points)
    uint256 public constant DROP_WARN_LOW    = 1500; // 15%
    uint256 public constant DROP_WARN_HIGH   = 2500; // 25%
    uint256 public constant DROP_ACTION_HIGH = 4500; // 45%

    // Precision
    uint256 public constant PRECISION = 10000;

    // ============================================================
    // STATE
    // ============================================================

    address public owner;
    address public immutable oracle;     // EWBGorillaOracle
    address public l1Token;    // EWBLayer1Token
    address public l2Token;    // EWBLayer2Token
    address public l3Token;    // EWBLayer3Token
    address public immutable whaleVault; // EWBWhaleVault

    // Price snapshot for drift tracking
    uint256 public baselineFloorETH;     // floor at time of deployment
    uint256 public lastSnapshotFloorETH; // most recent recorded floor
    uint256 public lastSnapshotTime;
    uint256 public snapshotCount;

    // Alert tracking
    bool    public warningActive;
    bool    public actionActive;
    uint256 public warningTriggeredAt;
    uint256 public actionTriggeredAt;

    struct PriceSnapshot {
        uint256 floorETH;
        uint256 ethUSD;
        uint256 floorUSD;
        uint256 timestamp;
        bool    isManualFloor;
        uint256 dropFromBaseline; // basis points
    }

    PriceSnapshot[] public snapshots;

    // ============================================================
    // EVENTS
    // ============================================================

    event OracleConnected(address oracle, uint256 floorETH);
    event LayerTokensConnected(address l1, address l2, address l3);
    event PriceSnapshotTaken(uint256 floorETH, uint256 floorUSD,
        bool isManual, uint256 dropBps);
    event WarningTriggered(uint256 floorETH, uint256 dropBps);
    event ActionTriggered(uint256 floorETH, uint256 dropBps);
    event WarningCleared(uint256 floorETH);
    event ActionCleared(uint256 floorETH);
    event BaselineUpdated(uint256 newBaseline);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyOwner() { require(msg.sender == owner, "Only owner"); _; }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(address _oracle, address _whaleVault) {
        require(_oracle     != address(0), "Invalid oracle");
        require(_whaleVault != address(0), "Invalid whaleVault");
        owner      = msg.sender;
        oracle     = _oracle;
        whaleVault = _whaleVault;

        // Read and store baseline floor price
        uint256 floor = IEWBGorillaOracle(_oracle).getFloorPriceETH();
        baselineFloorETH     = floor;
        lastSnapshotFloorETH = floor;
        lastSnapshotTime     = block.timestamp;

        emit OracleConnected(_oracle, floor);
    }

    // ============================================================
    // CONNECT LAYER TOKENS
    // ============================================================

    /**
     * @notice Connect all three layer token contracts
     */
    function connectLayerTokens(
        address _l1,
        address _l2,
        address _l3
    ) external onlyOwner {
        require(_l1 != address(0) && _l2 != address(0) &&
                _l3 != address(0), "Invalid addresses");
        l1Token = _l1;
        l2Token = _l2;
        l3Token = _l3;
        emit LayerTokensConnected(_l1, _l2, _l3);
    }

    // whaleVault is immutable — set in constructor only

    // ============================================================
    // LIVE PRICE READS
    // ============================================================

    /**
     * @notice Get current floor price from oracle (TWAP or manual)
     * @return floorETH  Floor price in ETH (18 decimals)
     * @return floorUSD  Floor price in USD (6 decimals)
     * @return isManual  True if using manual floor, false if TWAP
     * @return twapWindow TWAP window in seconds
     */
    function getCurrentFloor() external view returns (
        uint256 floorETH,
        uint256 floorUSD,
        bool    isManual,
        uint32  twapWindow
    ) {
        floorETH   = IEWBGorillaOracle(oracle).getFloorPriceETH();
        floorUSD   = IEWBGorillaOracle(oracle).getFloorPriceUSD();
        isManual   = IEWBGorillaOracle(oracle).useManualFloor();
        twapWindow = IEWBGorillaOracle(oracle).twapWindow();
    }

    /**
     * @notice Get live USD values for all three layers
     * @return l1USD  Layer 1 current USD value
     * @return l2USD  Layer 2 current USD value
     * @return l3USD  Layer 3 current USD value
     * @return totalUSD Combined stack USD value
     */
    function getLiveLayerValues() external view returns (
        uint256 l1USD,
        uint256 l2USD,
        uint256 l3USD,
        uint256 totalUSD
    ) {
        uint256 floorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();
        uint256 ethUSD   = IEWBGorillaOracle(oracle).getETHUSDPrice();

        // Layer values scale with ETH floor price
        // ETH/USD from Chainlink is 8 decimals
        // Result in USD no decimals
        l1USD    = STACK_L1_ETH * ethUSD / 1e26;
        l2USD    = STACK_L2_ETH * ethUSD / 1e26;
        l3USD    = STACK_L3_ETH * ethUSD / 1e26;
        totalUSD = l1USD + l2USD + l3USD;

        // Scale by current floor vs baseline
        uint256 floorRatio = floorETH * PRECISION / baselineFloorETH;
        l1USD    = l1USD    * floorRatio / PRECISION;
        l2USD    = l2USD    * floorRatio / PRECISION;
        l3USD    = l3USD    * floorRatio / PRECISION;
        totalUSD = l1USD + l2USD + l3USD;
    }

    /**
     * @notice Get floor drop from baseline in basis points
     * @return dropBps Basis points drop (0 = no drop, 1000 = 10%)
     * @return isRising True if floor is above baseline
     */
    function getFloorDrop() external view returns (
        uint256 dropBps,
        bool    isRising
    ) {
        uint256 current = IEWBGorillaOracle(oracle).getFloorPriceETH();
        if (current >= baselineFloorETH) {
            dropBps  = 0;
            isRising = true;
        } else {
            dropBps  = (baselineFloorETH - current) * PRECISION /
                        baselineFloorETH;
            isRising = false;
        }
    }

    /**
     * @notice Get current health status across all layers
     * @return status 0=SAFE 1=WARNING 2=ACTION 3=LIQUIDATE
     * @return currentFloorETH Current floor price
     * @return dropBps Current drop from baseline
     * @return healthFactor Current health factor (x100)
     */
    function getHealthStatus() external view returns (
        uint8   status,
        uint256 currentFloorETH,
        uint256 dropBps,
        uint256 healthFactor
    ) {
        currentFloorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();

        if (currentFloorETH >= baselineFloorETH) {
            dropBps = 0;
        } else {
            dropBps = (baselineFloorETH - currentFloorETH) * PRECISION /
                       baselineFloorETH;
        }

        // Health factor = current floor / baseline floor * 100
        healthFactor = currentFloorETH * HEALTH_LIQUIDATE /
                       baselineFloorETH;

        if (dropBps < DROP_WARN_LOW) {
            status = 0; // SAFE
        } else if (dropBps < DROP_WARN_HIGH) {
            status = 1; // WARNING Layer 1
        } else if (dropBps < DROP_ACTION_HIGH) {
            status = 2; // ACTION Layer 2
        } else {
            status = 3; // LIQUIDATE Layer 3
        }
    }

    /**
     * @notice Get TWAP source info
     * @return isUsingTWAP True if live TWAP active (not manual)
     * @return twapWindowDays TWAP window in days
     * @return manualAgeHours Hours since manual floor was set
     * @return manualExpiresIn Hours until manual floor expires
     */
    function getTWAPStatus() external view returns (
        bool    isUsingTWAP,
        uint256 twapWindowDays,
        uint256 manualAgeHours,
        uint256 manualExpiresIn
    ) {
        bool isManual    = IEWBGorillaOracle(oracle).useManualFloor();
        isUsingTWAP      = !isManual;
        twapWindowDays   = IEWBGorillaOracle(oracle).twapWindow() / 1 days;

        uint256 setAt    = IEWBGorillaOracle(oracle).manualFloorSetAt();
        uint256 maxAge   = IEWBGorillaOracle(oracle).manualFloorMaxAge();

        if (setAt > 0) {
            uint256 age  = block.timestamp - setAt;
            manualAgeHours = age / 1 hours;
            manualExpiresIn = age < maxAge
                ? (maxAge - age) / 1 hours
                : 0;
        }
    }

    // ============================================================
    // SNAPSHOT — RECORD PRICE ON-CHAIN
    // ============================================================

    /**
     * @notice Take a price snapshot and check thresholds
     * @dev Anyone can call — creates immutable price record
     *      Emits alerts if floor has dropped past thresholds
     */
    function takeSnapshot() external {
        uint256 floorETH = IEWBGorillaOracle(oracle).getFloorPriceETH();
        uint256 ethUSD   = IEWBGorillaOracle(oracle).getETHUSDPrice();
        uint256 floorUSD = floorETH * ethUSD / 1e20;
        bool    isManual = IEWBGorillaOracle(oracle).useManualFloor();

        uint256 dropBps;
        if (floorETH < baselineFloorETH) {
            dropBps = (baselineFloorETH - floorETH) * PRECISION /
                       baselineFloorETH;
        }

        snapshots.push(PriceSnapshot({
            floorETH:         floorETH,
            ethUSD:           ethUSD,
            floorUSD:         floorUSD,
            timestamp:        block.timestamp,
            isManualFloor:    isManual,
            dropFromBaseline: dropBps
        }));

        lastSnapshotFloorETH = floorETH;
        lastSnapshotTime     = block.timestamp;
        snapshotCount++;

        emit PriceSnapshotTaken(floorETH, floorUSD, isManual, dropBps);

        // Check and emit alerts
        _checkAlerts(floorETH, dropBps);
    }

    // ============================================================
    // INTERNAL — ALERT CHECKS
    // ============================================================

    function _checkAlerts(uint256 floorETH, uint256 dropBps) internal {
        // Warning zone: 15-25% drop
        if (dropBps >= DROP_WARN_LOW && dropBps < DROP_WARN_HIGH) {
            if (!warningActive) {
                warningActive       = true;
                warningTriggeredAt  = block.timestamp;
                emit WarningTriggered(floorETH, dropBps);
            }
        } else if (warningActive && dropBps < DROP_WARN_LOW) {
            warningActive = false;
            emit WarningCleared(floorETH);
        }

        // Action zone: 25-45% drop
        if (dropBps >= DROP_WARN_HIGH && dropBps < DROP_ACTION_HIGH) {
            if (!actionActive) {
                actionActive       = true;
                actionTriggeredAt  = block.timestamp;
                emit ActionTriggered(floorETH, dropBps);
            }
        } else if (actionActive && dropBps < DROP_WARN_HIGH) {
            actionActive = false;
            emit ActionCleared(floorETH);
        }
    }

    // ============================================================
    // ADMIN
    // ============================================================

    /**
     * @notice Update baseline floor (use when floor has risen significantly)
     */
    function updateBaseline() external onlyOwner {
        uint256 current = IEWBGorillaOracle(oracle).getFloorPriceETH();
        require(current > baselineFloorETH, "Floor has not risen");
        baselineFloorETH = current;
        emit BaselineUpdated(current);
    }

    // oracle is immutable — set in constructor only

    function getSnapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    function getLatestSnapshot() external view returns (
        uint256 floorETH,
        uint256 floorUSD,
        uint256 timestamp,
        bool    isManual,
        uint256 dropBps
    ) {
        require(snapshots.length > 0, "No snapshots yet");
        PriceSnapshot storage s = snapshots[snapshots.length - 1];
        return (s.floorETH, s.floorUSD, s.timestamp,
                s.isManualFloor, s.dropFromBaseline);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid");
        owner = newOwner;
    }
}
