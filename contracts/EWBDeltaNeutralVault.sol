// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

// ================================================================
// EWBDeltaNeutralVault — Main entry point (thin orchestrator)
// ================================================================
//
// All logic lives in the vault/ modules:
//
//   vault/VaultStorage.sol    — ALL state, events, modifiers (READ FIRST)
//   vault/VaultCore.sol       — deployLongLeg, harvest, compound, hedge
//   vault/VaultWithdrawal.sol — withdrawal lifecycle
//   vault/VaultEmergency.sol  — emergency exit pipeline
//   vault/VaultAdmin.sol      — parameter setters, views
//
// Inheritance chain (linear — no diamond):
//   EWBDeltaNeutralVault
//     └── VaultAdmin
//           └── VaultEmergency
//                 └── VaultWithdrawal
//                       └── VaultCore
//                             └── VaultStorage (ReentrancyGuard)
//
// CAPITAL FLOW:
//   Track A — NFT token IDs → EWBWhaleVault → lockId → lending/credit
//   Track B — Safe treasury ETH → this contract → Aave v3 (yield)
//   NFT holders do NOT send ETH here. See docs/ARCHITECTURE.md.
//
// AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
// ================================================================

import "./vault/VaultAdmin.sol";

contract EWBDeltaNeutralVault is VaultAdmin {

    string public constant VERSION = "1.0.0-coutts";

    constructor(
        address _safeMultisig,
        address _coldWallet,
        address _revenueRouter
    ) VaultStorage(_safeMultisig, _coldWallet, _revenueRouter) {}

    // receive() inherited from VaultAdmin
}
