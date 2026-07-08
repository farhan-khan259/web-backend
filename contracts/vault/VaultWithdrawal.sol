// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// ================================================================
// VaultWithdrawal — setWithdrawalTimelock, requestWithdrawal,
//                   withdrawAll, withdrawPartial
// ================================================================

import "./VaultCore.sol";

abstract contract VaultWithdrawal is VaultCore {
    ///         The delta-neutral strategy does NOT lose yield during this window.
    /// @notice Withdrawal delay — configurable by Safe multisig.
    ///         Private vault: set as low as 1 hour if you are the sole operator.
    ///         Min 1 hour enforced to prevent instant drain even with compromised Safe.
    uint256 public withdrawalTimelock = 24 hours;

    // WITHDRAWAL_TIMELOCK_MIN removed — private vault owner can set 0 for instant access
    uint256 public constant WITHDRAWAL_TIMELOCK_MAX = 7 days;

    event WithdrawalTimelockUpdated(uint256 oldSeconds, uint256 newSeconds);

    /// @notice Set the withdrawal timelock. 0 = instant access (private vault default). Max 7 days.
    /// @param _seconds Timelock in seconds. 0 for instant, up to 604800 (7 days).
    function setWithdrawalTimelock(uint256 _seconds) external onlyOwner {
        // Policy: 0 = instant withdrawal of own capital
        require(_seconds <= WITHDRAWAL_TIMELOCK_MAX, "Max 7 days"); // M-2 FIX: duplicate require removed
        emit WithdrawalTimelockUpdated(withdrawalTimelock, _seconds);
        withdrawalTimelock = _seconds;
    }
    bool    public withdrawalPending;

    /**
     * @notice Request a withdrawal — starts 24hr timelock
     * @dev After 24hrs, executeWithdrawal() can be called
     *      Prevents instant extraction if Safe is compromised
     */
    /// @notice Queue a withdrawal request. Starts the withdrawalTimelock countdown.
    function requestWithdrawal() external onlyOwner {
        withdrawalRequestedAt = block.timestamp;
        withdrawalPending     = true;
    }

    /// @notice Withdraw all deployed ETH from Aave. Requires timelock elapsed (if set).
    /// @dev Fully exits Aave position. Returned ETH goes to Safe multisig.
    function withdrawAll() external onlyOwner {
        require(withdrawalPending, "Must call requestWithdrawal() first");
        require(
            withdrawalTimelock == 0 || block.timestamp >= withdrawalRequestedAt + withdrawalTimelock,
            "24hr timelock not elapsed"
        );
        withdrawalPending = false;
        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        require(healthFactor >= minWithdrawHealthFactor, "Health factor too low for full withdrawal"); // M-1 FIX: was 1e18 (liquidation boundary)

        uint256 withdrawn = IAaveV3Pool(AAVE_V3_POOL).withdraw(
            WSTETH, type(uint256).max, safeMultisig); // M-08 fix: to safeMultisig not owner
        totalDeployed = 0;
        emit CapitalWithdrawn(withdrawn, safeMultisig);
    }

    // M-06/L-01 fix: withdrawPartial now requires same 24hr timelock as withdrawAll
    /// @notice Withdraw a specific ETH amount from Aave. Health factor enforced.
    /// @param amount ETH amount to withdraw (in wei).
    function withdrawPartial(uint256 amount) external onlyOwner {
        require(withdrawalPending, "Must call requestWithdrawal() first");
        require(
            withdrawalTimelock == 0 || block.timestamp >= withdrawalRequestedAt + withdrawalTimelock,
            "24hr timelock not elapsed"
        );
        withdrawalPending = false;
        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        require(healthFactor >= minWithdrawHealthFactor,
            "Health factor too low for partial withdrawal");

        // H-04 fix: withdraw WSTETH (what Aave holds), send to safeMultisig
        uint256 withdrawn = IAaveV3Pool(AAVE_V3_POOL).withdraw(WSTETH, amount, safeMultisig);
        totalDeployed = totalDeployed > amount ? totalDeployed - amount : 0;
        emit CapitalWithdrawn(withdrawn, safeMultisig);
    }

    // ------------------------------------------------------------------ //
    //  EMERGENCY EXIT
    // ------------------------------------------------------------------ //

    // ================================================================
}
