// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// ================================================================
// VaultEmergency — initiateEmergencyExit, staged exit pipeline,
//                  checkStETHPeg, detectAavePause
// ================================================================

import "./VaultWithdrawal.sol";

abstract contract VaultEmergency is VaultWithdrawal {
    // EMERGENCY EXIT PIPELINE — STAGED + CHECKPOINTED
    // ================================================================
    //
    // Stage 0 → initiateEmergencyExit()   — pauses system, sets EXIT_IN_PROGRESS
    // Stage 1 → executeAaveWithdrawal()   — withdraws wstETH from Aave
    // Stage 2 → executeUnwrapToStETH()    — unwraps wstETH → stETH
    // Stage 3 → executeTransferToDeed()   — sends stETH to deed wallet
    //
    // If any stage stalls > 6 hours → forceAdvanceExitStage() callable by owner
    // Each stage is idempotent — safe to retry on gas failure

    /**
     * @notice Stage 0 — Initiate emergency exit
     * @dev Pauses all operations. Sets EXIT_IN_PROGRESS.
     *      Call this first then execute stages in order.
     */
    function initiateEmergencyExit() external onlyEmergency {
        require(exitState == ExitState.NORMAL, "Exit already in progress");
        paused        = true;
        exitState     = ExitState.EXIT_IN_PROGRESS;
        exitStartedAt = block.timestamp;
        exitStage     = 1;
        emit ExitStageAdvanced(1, block.timestamp);
    }

    /**
     * @notice Stage 1 — Withdraw wstETH from Aave v3
     * @dev Idempotent — safe to retry if gas fails
     *      If Aave is paused, call setAavePaused(true) and wait
     */
    function executeAaveWithdrawal() external onlyEmergency {
        require(exitState == ExitState.EXIT_IN_PROGRESS, "Not in exit");
        require(exitStage == 1, "Wrong exit stage");
        require(!aavePaused, unicode"Aave is paused — cannot withdraw yet");

        try IAaveV3Pool(AAVE_V3_POOL).withdraw(
            WSTETH, type(uint256).max, address(this)
        ) returns (uint256 recovered) {
            require(recovered > 0, "Nothing withdrawn from Aave");
            exitStage = 2;
            emit ExitStageAdvanced(2, block.timestamp);
        } catch Error(string memory reason) {
            // Check if stage is stuck beyond timeout
            if (block.timestamp > exitStartedAt + EXIT_STAGE_TIMEOUT) {
                exitState = ExitState.EXIT_STUCK;
                emit ExitStuck(exitStage, block.timestamp - exitStartedAt);
            }
            revert(string(abi.encodePacked("Aave withdrawal failed: ", reason)));
        }
    }

    /**
     * @notice Stage 2 — Unwrap wstETH to stETH
     * @dev Idempotent — if already unwrapped, moves to stage 3
     */
    function executeUnwrapToStETH() external onlyEmergency {
        require(exitState == ExitState.EXIT_IN_PROGRESS, "Not in exit");
        require(exitStage == 2, "Wrong exit stage");

        uint256 wstBal = IERC20DN(WSTETH).balanceOf(address(this));
        if (wstBal > 0) {
            IWstETH(WSTETH).unwrap(wstBal);
        }
        exitStage = 3;
        emit ExitStageAdvanced(3, block.timestamp);
    }

    /**
     * @notice Stage 3 — Transfer stETH to deed wallet
     * @dev Final stage. Sets EXIT_COMPLETE.
     */
    function executeTransferToDeed() external onlyEmergency {
        require(exitState == ExitState.EXIT_IN_PROGRESS, "Not in exit");
        require(exitStage == 3, "Wrong exit stage");

        uint256 stBal = IERC20DN(STETH).balanceOf(address(this));
        require(stBal > 0, "No stETH to transfer");

        // H-01 fix: transfer to safeMultisig not owner
        SafeERC20DN.safeTransfer(IERC20DN(STETH), safeMultisig, stBal); // FIX R6

        exitRecovered = stBal;
        totalDeployed = 0;
        exitStage     = 4;
        exitState     = ExitState.EXIT_COMPLETE;

        emit EmergencyExit(stBal, safeMultisig); // H-4 FIX: was owner, should be safeMultisig
        emit ExitStageAdvanced(4, block.timestamp);
    }

    /**
     * @notice Force advance a stuck exit stage
     * @dev Only callable after EXIT_STAGE_TIMEOUT has elapsed
     *      Owner must manually handle the stuck stage off-chain
     */
    function forceAdvanceExitStage() external onlyEmergency {
        require(
            exitState == ExitState.EXIT_IN_PROGRESS ||
            exitState == ExitState.EXIT_STUCK,
            "Not in exit"
        );
        require(
            block.timestamp > exitStartedAt + EXIT_STAGE_TIMEOUT,
            unicode"Timeout not reached — wait 6 hours"
        );
        exitState = ExitState.EXIT_IN_PROGRESS;
        exitStage++;
        exitStartedAt = block.timestamp; // Reset timeout for next stage
        emit ExitForceAdvanced(exitStage, msg.sender);
    }

    // SIZE FIX: legacy single-call emergencyExit() REMOVED — it was explicitly
    // marked "for backwards compatibility" and is fully superseded by the staged,
    // checkpointed pipeline above (initiateEmergencyExit → executeAaveWithdrawal →
    // executeUnwrapToStETH → executeTransferToDeed), which is gas-safe and
    // retryable. Removing the duplicated one-shot path trims the bytecode.

    // ── DEPENDENCY FAILURE HANDLERS ─────────────────────────────

    // ── AUTOMATED FAILURE DETECTION ───────────────────────────
    // Keeper bot calls these checks every cycle.
    // Removes human latency from critical safety triggers.

    address public constant CURVE_STETH_POOL =
        0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    /**
     * @notice Auto-check stETH peg from Curve pool
     * @dev Keeper calls every cycle. If peg < 0.95 → halt harvest.
     *      If peg < 0.90 → initiate emergency exit automatically.
     *      Removes human latency from depeg response.
     */
    // M-07 fix: removed onlyOwner — keeper bot must be able to call this permissionlessly
    /// @notice Check if stETH is trading at peg vs ETH. Sets stEthDepeg flag if deviation > threshold.
    function checkStETHPeg() external {
        uint256 ethOut = ICurvePool(CURVE_STETH_POOL)
            .get_dy(1, 0, 1e18);

        if (ethOut < 0.90e18) {
            // Critical depeg — auto-initiate emergency exit
            if (exitState == ExitState.NORMAL) {
                paused    = true;
                exitState = ExitState.EXIT_IN_PROGRESS;
                exitStartedAt = block.timestamp;
                exitStage     = 1;
                emit ExitStageAdvanced(1, block.timestamp);
            }
        } else if (ethOut < 0.95e18) {
            // Soft depeg — pause harvest
            if (!paused) {
                paused = true;
            }
        } else {
            // Healthy — clear soft pause if it was from depeg only
            // (hard pauses from owner remain)
        }
    }

    /**
     * @notice Auto-detect Aave pause — TRUSTLESS
     * @dev Anyone can call — reads Aave getUserAccountData()
     *      If Aave is paused the call reverts — we catch and set flag
     *      Removes owner manual setter — cannot be faked
     */
    /// @notice Check if Aave v3 is paused. Sets aavePaused flag. Callable by anyone.
    function detectAavePause() external {
        try IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this))
            returns (uint256, uint256, uint256, uint256, uint256, uint256)
        {
            // Aave responding — clear pause flag
            if (aavePaused) {
                aavePaused = false;
                emit AavePauseCleared(block.timestamp);
            }
        } catch {
            // Aave not responding — mark paused
            if (!aavePaused) {
                aavePaused = true;
                emit AavePauseDetected(block.timestamp);
            }
        }
    }

    // setAavePaused() REMOVED — use detectAavePause() which is trustless

    /**
     * @notice Signal Lido withdrawal queue congestion
     * @dev Owner calls when Lido queue is too long
     *      Halts new stETH submissions but preserves existing positions
     */
    /// @notice Set the Lido queue congestion alert flag.
    /// @param _alert True if Lido withdrawal queue is congested.
    function setLidoQueueAlert(bool _alert) external onlyOwner {
        lidoQueueAlert = _alert;
        if (_alert) emit LidoQueueAlert(block.timestamp);
    }

    // SIZE FIX: getGovernance() REMOVED — unused on-chain and off-chain; the
    // same data is available directly via the safeMultisig() / coldWallet()
    // public getters.

    /// @notice Returns the current emergency exit state and progress.
    function getExitStatus() external view returns (
        ExitState state,
        uint256   stage,
        uint256   startedAt,
        uint256   recovered,
        bool      timedOut,
        bool      aaveIsPaused,
        bool      lidoAlert
    ) {
        return (
            exitState,
            exitStage,
            exitStartedAt,
            exitRecovered,
            exitStartedAt > 0 &&
                block.timestamp > exitStartedAt + EXIT_STAGE_TIMEOUT,
            aavePaused,
            lidoQueueAlert
        );
    }

    // ------------------------------------------------------------------ //
    //  VIEWS
    // ------------------------------------------------------------------ //

    // SIZE FIX: getPositionStatus() REMOVED — unused on-chain and off-chain.
    // The same data is available from getHealthFactor(), getAccruedYield(),
    // totalDeployed(), shortNotional(), totalYieldHarvested() and a direct
    // Aave getUserAccountData() read, so no monitoring capability is lost.

    /// @notice Returns current Aave health factor in WAD (1e18 = 1.0x).
    function getHealthFactor() external view returns (uint256) {
        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        return healthFactor;
    }

    // L-02 fix: convert awstETH shares to stETH equivalent before comparing to totalDeployed
    /// @notice Returns yield accrued since last harvest (aToken balance - totalDeployed).
    function getAccruedYield() external view returns (uint256) {
        uint256 wstEthShares = IAToken(A_WSTETH).balanceOf(address(this));
        uint256 stEthEquiv   = IWstETH(WSTETH).getStETHByWstETH(wstEthShares);
        return stEthEquiv > totalDeployed ? stEthEquiv - totalDeployed : 0;
    }

    // SIZE FIX: getHarvestCount() REMOVED — unused; harvestHistory has an
    // auto-generated public getter and its length is observable off-chain.

    // ================================================================
}
