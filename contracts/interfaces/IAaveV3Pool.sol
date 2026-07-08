// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title IAaveV3Pool
 * @notice Shared interface for Aave V3 Pool interactions across EWB vault contracts
 */

interface IAaveV3Pool {
    // ── Supply ──────────────────────────────────────────────
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    // ── Withdraw ─────────────────────────────────────────────
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    // ── Borrow ───────────────────────────────────────────────
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    // ── Repay ────────────────────────────────────────────────
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);

    // ── User Account Data ────────────────────────────────────
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}
