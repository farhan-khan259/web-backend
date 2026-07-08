// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title EWBDevPayment
 * @notice $50,000 USDC escrow auto-released to developer on mainnet deployment.
 *
 * FIX (R1): Single-EOA OWNER replaced with safeMultisig — same Safe wallet
 *           used across the full EWB Vault Protocol.  A compromised single key
 *           could previously drain the escrow instantly; Safe M-of-N removes
 *           that single point of failure.
 *
 * FIX (R6): All ERC-20 transfers use SafeERC20.safeTransfer / safeTransferFrom
 *           (inlined below — no OZ import needed for a 140-line escrow).
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 */

// ── Inlined SafeERC20 helpers (avoids extra import for small contract) ──────

library SafeTransfer {
    /// @dev Reverts if transfer returns false or reverts (handles USDT-style tokens)
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: transferFrom failed");
    }
}

interface IEWBVault {
    function owner() external view returns (address);
}

contract EWBDevPayment {
    using SafeTransfer for IERC20;

    // ── FIX R1: safeMultisig replaces single EOA OWNER ──────────────────────
    // OWNER is now the Safe multisig address (M-of-N), not a single EOA.
    // This removes the single key-loss / key-leak risk on the escrow.
    address public immutable SAFE_MULTISIG;   // replaces OWNER
    address public immutable DEVELOPER;
    address public immutable USDC;
    uint256 public immutable PAYMENT_AMOUNT;

    bool    public funded;
    bool    public released;
    address public deployedVault;
    uint256 public deploymentBlock;

    event Funded(uint256 amount, address fundedBy);
    event DeploymentConfirmed(address vault, uint256 blockNumber, address adminKey);
    event PaymentReleased(address developer, uint256 amount, address vault, uint256 blockNumber);
    event Refunded(address multisig, uint256 amount);

    /// @dev Only the Safe multisig can operate this escrow
    modifier onlyMultisig() {
        require(msg.sender == SAFE_MULTISIG, "Only Safe multisig");
        _;
    }

    /**
     * @param _safeMultisig  The deployed Safe multisig address (M-of-N)
     * @param _developer     Developer payment destination wallet
     * @param _usdc          USDC token address (mainnet: 0xA0b86991...)
     */
    constructor(address _safeMultisig, address _developer, address _usdc) {
        require(_safeMultisig != address(0), "Invalid multisig");
        require(_developer    != address(0), "Invalid developer wallet");
        require(_usdc         != address(0), "Invalid USDC address");
        require(_developer    != _safeMultisig, "Developer cannot be multisig");
        SAFE_MULTISIG  = _safeMultisig;
        DEVELOPER      = _developer;
        USDC           = _usdc;
        PAYMENT_AMOUNT = 50_000 * 1e6; // 50,000 USDC (6 decimals)
    }

    // ── FUND ─────────────────────────────────────────────────────────────────

    /// @notice Fund the escrow with exactly PAYMENT_AMOUNT USDC.
    ///         Approve this contract for PAYMENT_AMOUNT before calling.
    function fund() external onlyMultisig {
        require(!funded,   "Already funded");
        require(!released, "Already released");
        // FIX R6: safeTransferFrom handles non-standard ERC-20 return values
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), PAYMENT_AMOUNT);
        funded = true;
        emit Funded(PAYMENT_AMOUNT, msg.sender);
    }

    // ── CONFIRM DEPLOYMENT ───────────────────────────────────────────────────

    /**
     * @notice Confirm the vault is deployed and release payment to developer.
     * @dev Verifies (1) a contract exists at vault address AND
     *              (2) vault.owner() == SAFE_MULTISIG (confirms admin key handover).
     * @param _vault  Deployed EWBDeltaNeutralVault (or WhaleVault) address
     */
    function confirmDeployment(address _vault) external onlyMultisig {
        require(funded,    "Escrow not funded");
        require(!released, "Already released");
        require(_vault != address(0), "Invalid vault address");

        // Check 1: A contract must exist at the address
        uint256 codeSize;
        assembly { codeSize := extcodesize(_vault) }
        require(codeSize > 0, "No contract at vault address");

        // Check 2: Vault admin key must be held by the Safe multisig
        address vaultOwner = IEWBVault(_vault).owner();
        require(vaultOwner == SAFE_MULTISIG,
            unicode"Vault owner is not Safe multisig — cannot release payment");

        deployedVault   = _vault;
        deploymentBlock = block.number;
        released        = true;

        emit DeploymentConfirmed(_vault, block.number, vaultOwner);

        // FIX R6: safeTransfer handles non-standard return values
        IERC20(USDC).safeTransfer(DEVELOPER, PAYMENT_AMOUNT);

        emit PaymentReleased(DEVELOPER, PAYMENT_AMOUNT, _vault, block.number);
    }

    // ── REFUND ───────────────────────────────────────────────────────────────

    /// @notice Refund escrow to multisig if deployment does not proceed.
    function refund() external onlyMultisig {
        require(funded,    "Nothing to refund");
        require(!released, "Already released");
        uint256 balance = IERC20(USDC).balanceOf(address(this));
        require(balance > 0, "No USDC to refund");
        funded = false;
        // FIX R6: safeTransfer
        IERC20(USDC).safeTransfer(SAFE_MULTISIG, balance);
        emit Refunded(SAFE_MULTISIG, balance);
    }

    // ── VIEWS ────────────────────────────────────────────────────────────────

    function getStatus() external view returns (
        address multisig,
        address developer,
        uint256 paymentAmount,
        bool    isFunded,
        bool    isReleased,
        uint256 balance,
        address vault,
        uint256 blockNumber
    ) {
        return (
            SAFE_MULTISIG, DEVELOPER, PAYMENT_AMOUNT, funded, released,
            IERC20(USDC).balanceOf(address(this)),
            deployedVault, deploymentBlock
        );
    }

    function isReady() external view returns (bool) {
        return funded && !released;
    }
}
