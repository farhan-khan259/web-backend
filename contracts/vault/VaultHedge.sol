// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

// ================================================================
// VaultHedge — Hedge attestation + rebalance logic
// Extracted from VaultCore to reduce EWBDeltaNeutralVault bytecode
// ================================================================

import "./VaultStorage.sol";

abstract contract VaultHedge is VaultStorage {

    // ── ATTESTOR ROTATION ────────────────────────────────────
    address public pendingAttestor;
    uint256 public attestorRotationEta;
    uint256 public constant ATTESTOR_ROTATION_DELAY = 48 hours;

    // ── DRIFT TRACKING ───────────────────────────────────────
    bool    public rebalanceRequired;
    uint256 public lastDriftPct;

    // ── EVENTS ───────────────────────────────────────────────
    event AttestorRotationQueued(address indexed pending, uint256 eta);
    event AttestorRotationExecuted(address indexed oldAttestor, address indexed newAttestor);
    event AttestorRotationCancelled(address indexed pending);

    // ── ATTESTOR MANAGEMENT ──────────────────────────────────

    function setHedgeAttestor(address _attestor) external onlyOwner {
        require(_attestor != address(0), "Invalid attestor");
        require(hedgeAttestor == address(0), unicode"Attestor already set — use rotateHedgeAttestor()");
        emit HedgeAttestorUpdated(hedgeAttestor, _attestor);
        hedgeAttestor = _attestor;
    }

    function queueAttestorRotation(address _newAttestor) external onlyOwner {
        require(_newAttestor != address(0), "Invalid attestor");
        require(_newAttestor != hedgeAttestor, "Same as current attestor");
        pendingAttestor     = _newAttestor;
        attestorRotationEta = block.timestamp + ATTESTOR_ROTATION_DELAY;
        emit AttestorRotationQueued(_newAttestor, attestorRotationEta);
    }

    function executeAttestorRotation() external onlyEmergency {
        require(pendingAttestor != address(0), "No rotation queued");
        require(block.timestamp >= attestorRotationEta, "Timelock not elapsed");
        address old    = hedgeAttestor;
        hedgeAttestor  = pendingAttestor;
        pendingAttestor        = address(0);
        attestorRotationEta    = 0;
        hedgeVerified          = false;
        emit AttestorRotationExecuted(old, hedgeAttestor);
        emit HedgeAttestorUpdated(old, hedgeAttestor);
    }

    // SIZE FIX: setHedgeQuorumAttestors() REMOVED together with the unused
    // 2-of-3 quorum state in VaultStorage (see note there). It set attestor
    // B/C that no code path ever consulted.

    function cancelAttestorRotation() external onlyOwner {
        require(pendingAttestor != address(0), "No rotation queued");
        address cancelled   = pendingAttestor;
        pendingAttestor     = address(0);
        attestorRotationEta = 0;
        emit AttestorRotationCancelled(cancelled);
    }

    // ── ATTESTATION ──────────────────────────────────────────

    function submitHedgeAttestation(
        uint256 _notional,
        uint256 _leverage,
        uint256 _marginUSD,
        uint256 _fundingRateBps,
        string  calldata _accountId,
        uint256 _dataTimestamp,
        bytes32 _nonce,
        bytes   calldata _signature
    ) external {
        require(hedgeAttestor != address(0), "No attestor registered");
        require(msg.sender == hedgeAttestor, "Only registered attestor");

        bytes32 nonceKey = keccak256(abi.encodePacked(hedgeAttestor, _nonce));
        require(!usedAttestationNonces[nonceKey], "Attestation nonce already used");
        usedAttestationNonces[nonceKey] = true;

        require(_dataTimestamp <= block.timestamp, "Data timestamp in future");
        require(block.timestamp - _dataTimestamp <= 15 minutes,
            unicode"Data timestamp too old — must be within 15 minutes");

        bytes32 dataHash = keccak256(abi.encodePacked(
            HedgeAttestationLib.buildHash(
                _notional, _leverage, _marginUSD,
                _fundingRateBps, _dataTimestamp, _accountId
            ),
            _nonce
        ));

        address recovered = HedgeAttestationLib.recoverSigner(dataHash, _signature);
        require(recovered == hedgeAttestor, "Signature does not match attestor");

        require(_notional > 0, "Notional cannot be zero");
        if (totalDeployed > 0) {
            uint256 diff = _notional > totalDeployed
                ? _notional - totalDeployed
                : totalDeployed - _notional;
            require(diff * 100 / totalDeployed <= 20,
                "Attested notional deviates >20% from long");
        }

        {
            (, , , , , uint256 onChainHF) =
                IAaveV3Pool(AAVE_V3_POOL).getUserAccountData(address(this));
            require(onChainHF >= 105e16,
                unicode"F4: Aave HF below 1.05x — attestation rejected (on-chain cross-check)");
            require(onChainHF >= minWithdrawHealthFactor,
                unicode"F4: Aave HF below vault minimum — attestation rejected");
            emit HedgeAaveCrossCheck(onChainHF, _notional, block.timestamp);
        }

        shortNotional       = _notional;
        dydxAccountId       = _accountId;
        shortLeverage       = _leverage;
        shortMarginUSD      = _marginUSD;
        lastFundingRateBps  = _fundingRateBps;
        lastHedgeTime       = block.timestamp;
        lastAttestationTime = block.timestamp;
        lastAttestationHash = dataHash;
        hedgeVerified       = true;

        if (attestationHistory.length < MAX_HISTORY_LENGTH) {
            attestationHistory.push(HedgeSnapshot({
                notional:       _notional,
                leverage:       _leverage,
                marginUSD:      _marginUSD,
                fundingRateBps: _fundingRateBps,
                timestamp:      block.timestamp,
                dataHash:       dataHash,
                attestedBy:     hedgeAttestor
            }));
        }

        emit HedgeAttested(
            hedgeAttestor, _notional, _fundingRateBps,
            dataHash, block.timestamp
        );

        if (totalDeployed > 0) {
            uint256 diff = _notional > totalDeployed
                ? _notional - totalDeployed
                : totalDeployed - _notional;
            uint256 driftPct = diff * 100 / totalDeployed;
            if (driftPct > rebalanceThreshold) {
                rebalanceRequired = true;
                emit HedgeDriftWarning(totalDeployed, _notional, driftPct);
            } else {
                rebalanceRequired = false;
            }
        }
    }

    function isHedgeAttestationFresh() public view returns (
        bool   fresh,
        uint256 age,
        uint256 maxAge
    ) {
        if (lastAttestationTime == 0) return (false, 0, ATTESTATION_MAX_AGE);
        age   = block.timestamp - lastAttestationTime;
        fresh = age <= ATTESTATION_MAX_AGE;
        maxAge = ATTESTATION_MAX_AGE;
    }

    function getAttestationStatus() external view returns (
        bool    fresh,
        uint256 age,
        uint256 lastNotional,
        uint256 lastFunding,
        uint256 lastMargin,
        bytes32 lastHash,
        uint256 historyLength,
        address attestor
    ) {
        (fresh, age, ) = isHedgeAttestationFresh();
        return (
            fresh, age,
            shortNotional, lastFundingRateBps, shortMarginUSD,
            lastAttestationHash, attestationHistory.length, hedgeAttestor
        );
    }

    function rebalanceHedge(
        uint256 _newNotional,
        string calldata _accountId
    ) external onlyOwner {
        (bool fresh, , ) = isHedgeAttestationFresh();
        require(fresh, unicode"STALE_HEDGE_ATTESTATION — submit attestation first");
        require(_newNotional > 0, "Invalid notional");
        require(totalDeployed > 0, "No long leg");

        if (shortNotional > 0) {
            uint256 attestDiff = _newNotional > shortNotional
                ? _newNotional - shortNotional
                : shortNotional - _newNotional;
            require(attestDiff * 100 / shortNotional <= rebalanceThreshold,
                unicode"Notional deviates from last attestation — submit fresh attestation first");
        }

        uint256 diff = _newNotional > totalDeployed
            ? _newNotional - totalDeployed
            : totalDeployed - _newNotional;
        require(diff * 100 / totalDeployed <= rebalanceThreshold,
            "Rebalanced position still outside threshold");

        shortNotional = _newNotional;
        dydxAccountId = _accountId;
        lastHedgeTime = block.timestamp;
        emit PositionRebalanced(totalDeployed, _newNotional);
    }

    // SIZE FIX: getHedgeStatus() REMOVED — unused on-chain and off-chain. The
    // same long/short/delta/drift data is derivable from totalDeployed(),
    // shortNotional() and getAttestationStatus().

    function checkHedgeDrift() external onlyOwner {
        if (totalDeployed == 0 || shortNotional == 0) return;
        uint256 diff = totalDeployed > shortNotional
            ? totalDeployed - shortNotional
            : shortNotional - totalDeployed;
        uint256 driftPct = diff * 100 / totalDeployed;
        lastDriftPct = driftPct;
        if (driftPct > rebalanceThreshold) {
            if (!rebalanceRequired) {
                rebalanceRequired = true;
                emit HedgeDriftWarning(totalDeployed, shortNotional, driftPct);
            }
        } else {
            rebalanceRequired = false;
        }
    }
}
