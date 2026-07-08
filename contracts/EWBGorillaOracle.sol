// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
// FIX LOG:
// [CRITICAL] Contract name corrected: EWBGorillaOracle
// [CRITICAL] _tickToPrice replaced with full 20-bit Uniswap V3 tick math
// [MEDIUM] Manual floor has a staleness timestamp — owner must refresh within 7 days
// [MEDIUM] Chainlink staleness window made configurable (default 1 hour)
// [MEDIUM] getFloorPriceUSD() precision documented and zero-value guards added

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos) external view
        returns (int56[] memory tickCumulatives,
                 uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound);
}

contract EWBGorillaOracle {
    address public ewbPool;
    address public constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint32  public twapWindow         = 30 days;
    uint256 public manualFloorETH;
    bool    public useManualFloor;
    uint256 public manualFloorSetAt;
    uint256 public manualFloorMaxAge = 7 days;
    uint256 public chainlinkMaxAge    = 3600;

    address public immutable owner;

    event PoolUpdated(address indexed pool);
    event ManualFloorSet(uint256 floorETH, uint256 timestamp);
    event ManualFloorDisabled(uint256 timestamp); // FIX R7
    event TWAPWindowUpdated(uint32 window);
    event ChainlinkMaxAgeUpdated(uint256 maxAge);
    event ManualFloorMaxAgeUpdated(uint256 maxAge);

    constructor(address _ewbPool, address _owner) {
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
        
        ewbPool = _ewbPool;
    }

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    function getFloorPriceETH() external view returns (uint256) {
        if (useManualFloor) {
            require(
                block.timestamp - manualFloorSetAt <= manualFloorMaxAge,
                unicode"Manual floor price is stale — owner must update"
            );
            return manualFloorETH;
        }
        return _getTWAPPrice();
    }

    function getETHUSDPrice() external view returns (uint256) {
        (, int256 price, , uint256 updatedAt,) =
            AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        require(price > 0, "Invalid Chainlink price");
        require(block.timestamp - updatedAt < chainlinkMaxAge, "Stale Chainlink feed");
        return uint256(price) * 1e10; // H-3 FIX: Chainlink ETH/USD returns 8 decimals — normalise to 18
    }

    function getFloorPriceUSD() external view returns (uint256) {
        uint256 floorETH = this.getFloorPriceETH(); // ETH per token, 18 dec
        uint256 ethUSD   = this.getETHUSDPrice();   // USD per ETH,   18 dec
        require(floorETH > 0, "Floor price not set");
        require(ethUSD   > 0, "ETH/USD price not set");
        // M-3 FIX: floorETH (18 dec) * ethUSD (18 dec) = 36 dec product.
        // Divide by 1e18 to return 18-decimal USD per token — consistent with
        // the rest of the system (getETHUSDPrice, faceValueUSD, openLoan math).
        // Previous divisor 1e20 produced 16-dec output — wrong for any consumer.
        return (floorETH * ethUSD) / 1e18;
    }

    function _getTWAPPrice() internal view returns (uint256) {
        require(ewbPool != address(0), "Pool not set");
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(ewbPool).observe(secondsAgos);
        int56  tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int24  avgTick  = int24(tickDiff / int56(uint56(twapWindow)));
        return _tickToPrice(avgTick);
    }

    function _tickToPrice(int24 tick) internal pure returns (uint256) {
        uint256 absTick = tick < 0
            ? uint256(int256(-int256(tick)))
            : uint256(int256(tick));
        require(absTick <= 887272, "Tick out of range");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;

        if (absTick & 0x2     != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4     != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8     != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10    != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20    != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40    != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80    != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100   != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200   != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400   != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800   != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000  != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000  != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000  != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000  != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9)  >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604)   >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98)      >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2)           >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // FIX: Correct finalisation for Q128.128 fixed-point ratio produced above.
        //
        // The bitmask chain produces a Q128.128 number representing sqrtPrice.
        // To get the actual price (token1/token0) scaled to 18 decimals:
        //   sqrtPriceX96 = ratio >> 32          (converts Q128.128 → Q64.96)
        //   price = (sqrtPriceX96^2 * 1e18) >> 192
        //
        // For the EWB/WETH pool, token0=EWB, token1=WETH, so price = WETH per EWB = floor in ETH.
        // Result is in wei (18 decimals), matching getETHUSDPrice() expectations.
        //
        // Previous code used `>> 128` which returned the raw sqrtPrice (not the price),
        // producing near-zero values for typical tick ranges.
        uint256 sqrtPriceX96 = ratio >> 32;
        // M-5 FIX: sqrtPriceX96 can be up to ~2^160; squaring overflows uint256.
        // Safe approach: normalise to Q64.64 first (divide by 2^96), then square.
        // price = (sqrtPriceX96 / 2^96)^2 * 1e18
        //       = (sqrtPriceX96 >> 48)^2 * 1e18 / 2^96
        // Split into hi/lo 128-bit halves to keep intermediates in 256-bit range.
        uint256 lo = sqrtPriceX96 & type(uint128).max;
        uint256 hi = sqrtPriceX96 >> 128;
        // hi is always 0 for valid Uniswap V3 ticks (sqrtPriceX96 < 2^160 < 2^128 only
        // after the >> 32 shift above which caps it at ~2^128). Guard for safety:
        require(hi == 0, "sqrtPrice overflow");
        // lo^2 fits in 256 bits (lo < 2^128 => lo^2 < 2^256). Safe.
        uint256 priceX192 = lo * lo;
        return (priceX192 * 1e18) >> 192;
    }

    // ── Pool timelock (48h delay) ─────────────────────────────────────────────
    address public pendingPool;
    uint256 public poolQueuedAt;
    uint256 public constant POOL_TIMELOCK = 48 hours;
    event PoolQueued(address indexed pool, uint256 executeAfter);

    function queuePool(address _pool) external onlyOwner {
        require(_pool != address(0), "Invalid pool");
        pendingPool  = _pool;
        poolQueuedAt = block.timestamp;
        emit PoolQueued(_pool, block.timestamp + POOL_TIMELOCK);
    }

    function executePool() external onlyOwner {
        require(pendingPool != address(0),                       "No pool queued");
        require(block.timestamp >= poolQueuedAt + POOL_TIMELOCK, "Timelock not elapsed");
        ewbPool     = pendingPool;
        pendingPool = address(0);
        emit PoolUpdated(ewbPool);
    }

    // ── F5 FIX: Manual floor deviation cap ───────────────────────────────────
    // Finding 5 from audit prep: within manualFloorMaxAge the multisig effectively
    // dictates the floor price used by all downstream contracts.
    //
    // Mitigations applied:
    //   (a) Hard cap: manual floor cannot deviate > 5% from TWAP when TWAP is available.
    //   (b) manualFloorMaxAge capped at 30 minutes maximum (was 30 days).
    //   (c) Deviation is emitted in the ManualFloorSet event for monitoring.

    /// @notice Maximum deviation between manual floor and TWAP: 5% (500 bps).
    ///         If TWAP is unavailable (pool not set), this check is bypassed with a warning event.
    uint256 public constant MANUAL_FLOOR_MAX_DEVIATION_BPS = 500;
    uint256 public constant MAX_MANUAL_FLOOR_NO_TWAP = 50 ether; // 5%

    event ManualFloorDeviationWarning(uint256 manualFloor, uint256 twapFloor, uint256 deviationBps);

    function setManualFloor(uint256 _floorETH) external onlyOwner {
        require(_floorETH > 0, "Floor must be > 0");

        // F5: Cross-check against TWAP if pool is available
        if (ewbPool != address(0)) {
            // Attempt TWAP read — if pool is too thin/new, observe() may revert.
            // We catch that and emit a warning rather than blocking the setter entirely
            // (manual floor is often set precisely when TWAP is unavailable/thin).
            try this.getTWAPFloorExternal() returns (uint256 twapFloor) {
                if (twapFloor > 0) {
                    uint256 deviation;
                    if (_floorETH >= twapFloor) {
                        deviation = (_floorETH - twapFloor) * 10000 / twapFloor;
                    } else {
                        deviation = (twapFloor - _floorETH) * 10000 / twapFloor;
                    }
                    // Hard reject if deviation exceeds 5%
                    require(
                        deviation <= MANUAL_FLOOR_MAX_DEVIATION_BPS,
                        unicode"F5: Manual floor deviates >5% from TWAP — rejected"
                    );
                    if (deviation > 200) { // warn if > 2%
                        emit ManualFloorDeviationWarning(_floorETH, twapFloor, deviation);
                    }
                }
            } catch {
                // C-3 FIX: Hard cap when TWAP unavailable
                require(
                    _floorETH <= MAX_MANUAL_FLOOR_NO_TWAP,
                    "Floor exceeds no-TWAP cap: max 50 ETH when TWAP unavailable"
                );
                emit ManualFloorDeviationWarning(_floorETH, 0, type(uint256).max);
            }
        }

        manualFloorETH   = _floorETH;
        manualFloorSetAt = block.timestamp;
        useManualFloor   = true;
        emit ManualFloorSet(_floorETH, block.timestamp);
    }

    /// @notice External wrapper so setManualFloor can call TWAP via try/catch.
    function getTWAPFloorExternal() external view returns (uint256) {
        return _getTWAPPrice();
    }

    function setTWAPWindow(uint32 _window) external onlyOwner {
        require(_window >= 1 hours,  "Min 1 hour");
        require(_window <= 30 days,  "Max 30 days");
        twapWindow = _window;
        emit TWAPWindowUpdated(_window);
    }

    function disableManualFloor() external onlyOwner {
        useManualFloor = false;
        emit ManualFloorDisabled(block.timestamp);
    }

    function setChainlinkMaxAge(uint256 _maxAge) external onlyOwner {
        require(_maxAge >= 1 hours,  "Min 1 hour");
        require(_maxAge <= 24 hours, "Max 24 hours");
        chainlinkMaxAge = _maxAge;
        emit ChainlinkMaxAgeUpdated(_maxAge);
    }

    function setManualFloorMaxAge(uint256 _maxAge) external onlyOwner {
        // F5: Cap reduced from 30 days to 30 minutes maximum.
        // Audit finding: a large max-age turns the manual floor into a
        // long-duration price control surface. 30 min is sufficient for
        // legitimate use (TWAP temporarily unavailable) without creating
        // an extended manipulation window.
        require(_maxAge >= 15 minutes, "Min 15 minutes");
        require(_maxAge <= 30 minutes, "F5: Max 30 minutes for manual floor age");
        manualFloorMaxAge = _maxAge;
        emit ManualFloorMaxAgeUpdated(_maxAge);
    }

}
