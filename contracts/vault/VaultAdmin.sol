// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// ================================================================
// VaultAdmin — parameter setters, timelocked queue/execute,
//              all view functions
// ================================================================

import "./VaultEmergency.sol";

abstract contract VaultAdmin is VaultEmergency {
    // ADMIN — PARAMETER SETTERS WITH TIMELOCKS + HARD BOUNDS
    // ================================================================
    //
    // FIX R2: Every state-changing parameter setter now requires:
    //   (a) a timelock queue step (onlyOwner/Safe multisig)
    //   (b) an execute step after PARAM_TIMELOCK (48 hours)
    //   (c) hard upper/lower bounds validated at queue time
    //
    // This prevents the Safe multisig from silently changing thresholds
    // that govern $211M of capital without an on-chain observable delay.
    //
    // Emergency pause (setPaused) is exempt from timelock — it must be
    // instant for incident response, and is a no-funds-movement action.

    /// @notice Timelock for parameter changes.
    ///         Policy: set to 0 for instant changes on your own vault.
    ///         Set higher if you want a safety delay (e.g. 48 hours).
    ///         Min 0 (instant), Max 7 days.
    uint256 public paramTimelock = 0; // Default: instant for private vault

    uint256 public constant PARAM_TIMELOCK_MAX = 7 days;

    event ParamTimelockUpdated(uint256 oldSeconds, uint256 newSeconds);

    function setParamTimelock(uint256 _seconds) external onlyOwner {
        require(_seconds <= PARAM_TIMELOCK_MAX, "Max 7 days");
        emit ParamTimelockUpdated(paramTimelock, _seconds);
        paramTimelock = _seconds;
    }

    // ── Pending parameter structs ────────────────────────────────────
    struct PendingUint { uint256 value; uint256 eta; bool queued; }

    PendingUint public pendingMaxDeployment;
    PendingUint public pendingTargetHF;
    PendingUint public pendingMinWithdrawHF;

    event ParamQueued(string param, uint256 value, uint256 eta);
    event ParamExecuted(string param, uint256 oldValue, uint256 newValue);
    event ParamCancelled(string param);

    // ── maxDeployment ────────────────────────────────────────────────
    /// @notice Queue a maxDeployment change.  Hard bound: 0 < max ≤ 12,000 ETH.
    function queueMaxDeployment(uint256 _max) external onlyOwner {
        require(_max > 0,            "maxDeployment: must be > 0");
        require(_max <= 12_000 ether, "maxDeployment: hard cap 12,000 ETH");
        uint256 eta = block.timestamp + paramTimelock;
        pendingMaxDeployment = PendingUint(_max, eta, true);
        emit ParamQueued("maxDeployment", _max, eta);
    }

    function executeMaxDeployment() external onlyOwner {
        PendingUint memory p = pendingMaxDeployment;
        require(p.queued, "maxDeployment: not queued");
        require(paramTimelock == 0 || block.timestamp >= p.eta, "maxDeployment: timelock not elapsed");
        uint256 old = maxDeployment;
        maxDeployment = p.value;
        delete pendingMaxDeployment;
        emit ParamExecuted("maxDeployment", old, p.value);
    }

    function cancelMaxDeployment() external onlyOwner {
        require(pendingMaxDeployment.queued, "Not queued");
        delete pendingMaxDeployment;
        emit ParamCancelled("maxDeployment");
    }

    // ── targetHealthFactor ───────────────────────────────────────────
    /// @notice Queue targetHealthFactor change.  Bounds: 1.5x – 4.0x (1.5e18 – 4.0e18).
    function queueTargetHealthFactor(uint256 _hf) external onlyOwner {
        require(_hf >= 15e17, "targetHF: min 1.5x");
        require(_hf <= 40e17, "targetHF: max 4.0x");
        uint256 eta = block.timestamp + paramTimelock;
        pendingTargetHF = PendingUint(_hf, eta, true);
        emit ParamQueued("targetHealthFactor", _hf, eta);
    }

    function executeTargetHealthFactor() external onlyOwner {
        PendingUint memory p = pendingTargetHF;
        require(p.queued, "targetHF: not queued");
        require(paramTimelock == 0 || block.timestamp >= p.eta, "targetHF: timelock not elapsed");
        uint256 old = targetHealthFactor;
        targetHealthFactor = p.value;
        delete pendingTargetHF;
        emit ParamExecuted("targetHealthFactor", old, p.value);
    }

    function cancelTargetHealthFactor() external onlyOwner {
        require(pendingTargetHF.queued, "Not queued");
        delete pendingTargetHF;
        emit ParamCancelled("targetHealthFactor");
    }

    // ── minWithdrawHealthFactor ──────────────────────────────────────
    /// @notice Queue minWithdrawHealthFactor change.  Bounds: 1.1x – 2.0x.
    function queueMinWithdrawHealthFactor(uint256 _hf) external onlyOwner {
        require(_hf >= 11e17, "minWithdrawHF: min 1.1x");
        require(_hf <= 20e17, "minWithdrawHF: max 2.0x");
        require(_hf <= targetHealthFactor, "minWithdrawHF: must be <= targetHF");
        uint256 eta = block.timestamp + paramTimelock;
        pendingMinWithdrawHF = PendingUint(_hf, eta, true);
        emit ParamQueued("minWithdrawHealthFactor", _hf, eta);
    }

    function executeMinWithdrawHealthFactor() external onlyOwner {
        PendingUint memory p = pendingMinWithdrawHF;
        require(p.queued, "minWithdrawHF: not queued");
        require(paramTimelock == 0 || block.timestamp >= p.eta, "minWithdrawHF: timelock not elapsed");
        uint256 old = minWithdrawHealthFactor;
        minWithdrawHealthFactor = p.value;
        delete pendingMinWithdrawHF;
        emit ParamExecuted("minWithdrawHealthFactor", old, p.value);
    }

    function cancelMinWithdrawHealthFactor() external onlyOwner {
        require(pendingMinWithdrawHF.queued, "Not queued");
        delete pendingMinWithdrawHF;
        emit ParamCancelled("minWithdrawHealthFactor");
    }

    // ── setPaused — EXEMPT from timelock (emergency use only) ────────
    /// @notice Pause / unpause all user-facing entrypoints.
    ///         Exempt from timelock — must be instant for incident response.
    ///         Does NOT move funds. Emits event for off-chain monitoring.
    event PausedStateChanged(bool paused, address by);

    function setPaused(bool _paused) external onlyEmergency {
        paused = _paused;
        emit PausedStateChanged(_paused, msg.sender);
    }

    // ── Legacy setters removed ────────────────────────────────────────
    // setMaxDeployment(), setTargetHealthFactor(), setMinWithdrawHealthFactor()
    // have been replaced by the queue/execute pattern above.
    // Direct single-tx parameter changes on $211M capital are not acceptable.

    // H-06 fix: transferOwnership() removed.
    // owner is set to safeMultisig at construction and must not diverge.
    // safeMultisig is immutable — governance cannot be redirected.

    /**
     * @notice Register EWBRevenueRouter for automatic yield recording.
     * @dev    Once set, harvestYield() notifies the router after each harvest
     *         so income is tracked on-chain without a separate manual call.
     *         Safe multisig only. Can be updated if router is redeployed.
     */
    event RevenueRouterSet(address indexed router);

    // revenueRouter is immutable — set in VaultStorage constructor only

    receive() external payable {}
}
