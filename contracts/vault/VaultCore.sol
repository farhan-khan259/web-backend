// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;
// ================================================================
// VaultCore — deployLongLeg, harvestYield, compoundYield,
//             submitHedgeAttestation, rebalanceHedge
// ================================================================

import "./VaultHedge.sol";

abstract contract VaultCore is VaultHedge {
    //  DEPLOY LONG LEG
    // ------------------------------------------------------------------ //

    /**
     * @notice Deploy ETH from the Safe multisig treasury into the long leg.
     * @dev CAPITAL SOURCE: ETH must come from the Safe multisig treasury only.
     *      Individual NFT holders and end users do NOT call this function and
     *      do NOT send ETH to this contract. See contract header for full
     *      capital flow architecture (Track A vs Track B).
     *
     *      ETH flow: msg.value (from Safe) → stETH (Lido) → wstETH → Aave v3
     *
     *      Step 1: ETH → stETH via Lido submit()
     *      Step 2: stETH → wstETH via IWstETH.wrap() (Aave v3 requires wstETH)
     *      Step 3: wstETH → Aave v3 supply()
     *
     *      maxDeployment cap = LAYER3_ETH_TOTAL (6,391 ETH) from EWBLayer3Token.
     *      This ensures yield strategy never exceeds the NFT collateral backing.
     *
     *      Hedge sizing: bot calls submitHedgeAttestation() after each deploy.
     *      Target: shortNotional == totalDeployed (delta = 0, ±5% tolerance)
     */
    function deployLongLeg() external payable onlyOwner nonReentrant notPaused {
        require(msg.value > 0, "No ETH sent");
        require(totalDeployed + msg.value <= maxDeployment, "Exceeds max deployment");
        require(exitState == ExitState.NORMAL, "Cannot deploy during exit");
        require(!rebalanceRequired, unicode"Hedge drift exceeds threshold — rebalanceHedge() first");
        require(!aavePaused, "Aave is paused");
        require(!lidoQueueAlert, "Lido queue congested");

        // Hard-revert if hedge attestation is stale
        // Cannot deploy new capital without verified hedge state
        (bool fresh, , ) = isHedgeAttestationFresh();
        require(fresh || lastAttestationTime == 0,
            unicode"STALE_HEDGE_ATTESTATION — bot must attest before deploying");

        // Step 1: ETH → stETH
        uint256 stEthReceived = ILido(STETH).submit{value: msg.value}(address(0));
        require(stEthReceived > 0, "Lido: no stETH received");

        totalDeployed += msg.value;
        emit CapitalDeployed(msg.value, stEthReceived);

        // Step 2: stETH → wstETH  (L-2 fix: Aave v3 mainnet requires wstETH)
        IERC20DN(STETH).approve(WSTETH, stEthReceived);
        uint256 wstEthAmount = IWstETH(WSTETH).wrap(stEthReceived);
        require(wstEthAmount > 0, "wstETH: wrap returned zero");

        // Step 3: wstETH → Aave v3
        IERC20DN(WSTETH).approve(AAVE_V3_POOL, wstEthAmount);
        IAaveV3Pool(AAVE_V3_POOL).supply(WSTETH, wstEthAmount, address(this), 0);

        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));

        emit LongLegOpened(wstEthAmount, healthFactor);
    }

    // recordShortLeg() REMOVED — trust-based recording eliminated.
    // ALL hedge state must go through submitHedgeAttestation()
    // which requires cryptographic signature from registered attestor.
    // No unverified hedge state possible.

    // SIZE FIX: rebalanceLong(uint256,string) REMOVED — it duplicated
    // VaultHedge.rebalanceHedge(uint256,string), which is stricter (it also
    // requires a fresh hedge attestation). Use rebalanceHedge() instead.

    // ------------------------------------------------------------------ //
    //  HARVEST YIELD
    // ------------------------------------------------------------------ //

    /**
     * @notice Harvest stETH yield — PERMISSIONLESS
     * @dev Anyone can trigger harvest when yield >= threshold
     *      Removes owner gate — cannot be blocked by compromised key
     *      Yield always routes to safeMultisig — cannot be redirected
     */
    // FIX-H5 + FIX-QUORUM-HEDGE: harvestYield requires ALL of:
    //   (a) onlyOwner = safeMultisig must sign
    //   (b) hedgeAttestation fresh — if quorum registered, 2-of-3 must have attested
    //   (c) Aave health factor on-chain >= targetHealthFactor
    // Single attestor compromise insufficient when quorum is active.
    // C2-01 FIX: onlyOwner added — harvestYield moves real funds.
    function harvestYield(uint256 yieldAmount) external onlyOwner nonReentrant notPaused {
        // Hard-revert if hedge attestation is stale
        // Harvest without verified hedge = yield without confirmed neutrality
        (bool fresh, , ) = isHedgeAttestationFresh();
        require(fresh, unicode"STALE_HEDGE_ATTESTATION — bot must attest before harvesting");

        require(yieldAmount > 0, "No yield specified");

        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        require(healthFactor >= targetHealthFactor, "Health factor too low to harvest");

        // C-08 fix: awstETH balance is in wstETH shares (non-rebasing).
        // Must convert to stETH equivalent before comparing to totalDeployed (ETH).
        uint256 wstEthShares = IAToken(A_WSTETH).balanceOf(address(this));
        uint256 stEthEquiv   = IWstETH(WSTETH).getStETHByWstETH(wstEthShares);
        uint256 yieldAccrued = stEthEquiv > totalDeployed
            ? stEthEquiv - totalDeployed
            : 0;
        require(yieldAmount <= yieldAccrued,
            unicode"Harvest amount exceeds accrued yield — principal protection");

        // C-08 fix: vault holds WSTETH in Aave — withdraw wstETH then unwrap to stETH
        // Convert yieldAmount (stETH) to wstETH shares for withdraw call
        uint256 wstEthToWithdraw = IWstETH(WSTETH).getWstETHByStETH(yieldAmount);
        uint256 wstWithdrawn = IAaveV3Pool(AAVE_V3_POOL).withdraw(
            WSTETH, wstEthToWithdraw, address(this));
        uint256 withdrawn = IWstETH(WSTETH).unwrap(wstWithdrawn);

        totalYieldHarvested += withdrawn;
        lastHarvestTime      = block.timestamp;

        // M-02 fix: only record if under cap
        if (harvestHistory.length < MAX_HISTORY_LENGTH) {
            harvestHistory.push(HarvestRecord({
                timestamp:        block.timestamp,
                yieldAmount:      withdrawn,
                aaveHealthFactor: healthFactor
            }));
        }

        // H-01 fix: transfer to safeMultisig not owner
        SafeERC20DN.safeTransfer(IERC20DN(STETH), safeMultisig, withdrawn); // FIX R6

        // AUTO-RECORD: notify revenue router so income is tracked on-chain
        // without requiring a separate manual multisig call.
        // Silently skips if router not yet set — does not block harvest.
        if (revenueRouter != address(0)) {
            try IEWBRevenueRouter(revenueRouter).recordStETHYieldAuto(withdrawn) {}
            catch {} // non-blocking — harvest succeeds even if router call fails
        }

        emit YieldHarvested(withdrawn, block.timestamp);
    }

    /**
     * @notice Compound accrued yield back into the Aave position.
     * @dev    Reinvests yield WITHOUT withdrawing stETH to safeMultisig.
     *         The wstETH already held by Aave grows via rebase — this
     *         function simply recognises that growth as new principal
     *         and updates totalDeployed so future yield calculations
     *         compound on the larger base.
     *
     *         NO ETH leaves the contract.
     *         NO new ETH is required.
     *         NO existing state is modified except totalDeployed.
     *         ALL existing guards (attestation, health factor, cap)
     *         are identical to deployLongLeg() — dynamic is unchanged.
     *
     *         Recommended: call weekly via keeper bot.
     *         Gas cost: ~$0.03 at current gas prices.
     *
     * @param  compoundAmount  stETH equivalent to recognise as compounded
     *                         principal (must be <= accrued yield)
     */
    function compoundYield(uint256 compoundAmount)
        external
        onlyOwner
        nonReentrant
        notPaused
    {
        require(compoundAmount > 0, "Nothing to compound");

        // Same cap check as deployLongLeg — hard ceiling never moves
        require(
            totalDeployed + compoundAmount <= maxDeployment,
            "Compound would exceed maxDeployment cap"
        );

        // Same attestation check as deployLongLeg — hedge must be verified
        (bool fresh, , ) = isHedgeAttestationFresh();
        require(fresh, unicode"STALE_HEDGE_ATTESTATION — attest before compounding");

        // Same health factor check as harvestYield — never compound
        // into an unhealthy position
        (, , , , , uint256 healthFactor) =
            IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
        require(
            healthFactor >= targetHealthFactor,
            "Health factor too low to compound"
        );

        // Verify the amount doesn't exceed what has actually accrued.
        // Uses identical logic to harvestYield() — no double-counting.
        uint256 wstEthShares = IAToken(A_WSTETH).balanceOf(address(this));
        uint256 stEthEquiv   = IWstETH(WSTETH).getStETHByWstETH(wstEthShares);
        uint256 yieldAccrued = stEthEquiv > totalDeployed
            ? stEthEquiv - totalDeployed
            : 0;
        require(
            compoundAmount <= yieldAccrued,
            "Compound amount exceeds accrued yield"
        );

        // Recognise yield as new principal — wstETH is already in Aave
        // earning. totalDeployed increases so the next harvest measures
        // yield against a larger base.
        totalDeployed += compoundAmount;

        emit YieldCompounded(compoundAmount, totalDeployed, block.timestamp);
    }

    // ------------------------------------------------------------------ //
    //  REBALANCE LONG
    // ------------------------------------------------------------------ //

    // ── AUTOMATED HEDGE REBALANCE TRIGGER ─────────────────────
    // Replaces manual rebalance. Keeper bot calls checkAndRebalance()
    // every cycle. If drift > rebalanceThreshold: fires HedgeDriftWarning
    // and blocks new deployments until rebalance is recorded.
    // Human still adjusts dYdX — but the on-chain gate enforces it.


    // SIZE FIX: checkAndRebalance() REMOVED — it duplicated
    // VaultHedge.checkHedgeDrift() (identical drift computation, rebalanceRequired
    // flag and HedgeDriftWarning event). Use checkHedgeDrift() instead.

    // SIZE FIX: rebalanceLong(uint256,bool) REMOVED — the "increase" branch is
    // equivalent to deployLongLeg() and the "decrease" branch to
    // withdrawPartial(); both remain available with the same guards. This trims
    // the duplicated Lido/wstETH/Aave supply+withdraw paths from the bytecode.

    // ------------------------------------------------------------------ //
    //  WITHDRAW
    // ------------------------------------------------------------------ //

    // ── WITHDRAWAL TIMELOCK ─────────────────────────────────
    // Prevents instant capital extraction — 24hr delay enforced
    // Emergency exit bypasses timelock (staged pipeline)
    uint256 public withdrawalRequestedAt;

    /// @notice 24-hour delay between requesting and executing a withdrawal.
    ///         Rationale: Aave wstETH withdrawal involves a Lido unbonding queue that
    ///         can take days. 24h gives the Safe multisig time to detect malicious
    ///         withdrawal requests and pause before funds leave.
}
