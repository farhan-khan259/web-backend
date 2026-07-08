// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19; // M-04 fix: exact version, not caret

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// 2-of-2 multisig escrow for developer milestone payments
// Both owner AND developer must sign to release each milestone
// AUDIT REQUIRED BEFORE FUNDING WITH SIGNIFICANT AMOUNTS
// FIX LOG:
// [MEDIUM] getStatus() now returns correct ERC20 balance, not ETH balance, for token escrows
// [MEDIUM] updateDeveloper() now clears all existing milestone signatures from old developer
// [HIGH-H1] DISPUTE_TIMEOUT enforcement code added — claimDisputeRefund() after 90 days
// [MEDIUM] authorisedBalance tracker prevents forced ETH injection via selfdestruct/coinbase

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount)
        external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// FIX R6: Inlined SafeERC20 — handles non-standard tokens (USDT-style bool-less returns)
library SafeCall {
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeCall: transfer failed");
    }
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))),
            "SafeCall: transferFrom failed");
    }
}



contract EWBMilestoneEscrow is ReentrancyGuard {

    uint256 public constant DISPUTE_TIMEOUT = 90 days; // FIX: dispute resolution window

    address public owner;
    address public developer;
    bool    public ownerConfirmed;
    bool    public developerConfirmed;
    bool    public contractActive;
    address public paymentToken;

    struct Milestone {
        string  description;
        uint256 amount;
        bool    ownerSigned;
        bool    devSigned;
        bool    released;
        bool    cancelled;
        uint256 createdAt;
        uint256 releasedAt;
    }

    Milestone[] public milestones;

    uint256 public totalFunded;
    uint256 public totalReleased;

    event ContractActivated(address owner, address developer);
    event MilestoneAdded(uint256 indexed id, string description, uint256 amount);
    event MilestoneSigned(uint256 indexed id, address signer);
    event MilestoneReleased(uint256 indexed id, uint256 amount, address developer);
    event MilestoneCancelled(uint256 indexed id);
    event Funded(uint256 amount);
    event Refunded(address owner, uint256 amount);
    event DeveloperUpdated(address indexed oldDev, address indexed newDev);

    modifier onlyOwner()     { require(msg.sender == owner,     "Only owner");     _; }
    modifier onlyDeveloper() { require(msg.sender == developer, "Only developer"); _; }
    modifier onlyParty() {
        require(msg.sender == owner || msg.sender == developer,
            "Only owner or developer");
        _;
    }
    modifier whenActive() {
        require(contractActive, "Contract not yet active");
        _;
    }

    constructor(address _developer, address _paymentToken) {
        require(_developer != address(0), "Invalid developer address");
        require(_developer != msg.sender, "Owner and developer cannot be same");
        owner        = msg.sender;
        developer    = _developer;
        paymentToken = _paymentToken;
    }

    // ------------------------------------------------------------------ //
    //  ACTIVATION
    // ------------------------------------------------------------------ //

    function ownerConfirm() external onlyOwner {
        require(!ownerConfirmed, "Already confirmed");
        ownerConfirmed = true;
        _checkActivation();
    }

    function developerConfirm() external onlyDeveloper {
        require(!developerConfirmed, "Already confirmed");
        developerConfirmed = true;
        _checkActivation();
    }

    function _checkActivation() internal {
        if (ownerConfirmed && developerConfirmed) {
            contractActive = true;
            emit ContractActivated(owner, developer);
        }
    }

    // ------------------------------------------------------------------ //
    //  FUNDING
    // ------------------------------------------------------------------ //

    // FIX: Track authorised funding separately from raw contract balance
    // This protects against forced ETH injection via selfdestruct() or
    // coinbase block reward targeting which would inflate address(this).balance
    // without updating totalFunded, causing accounting disconnect
    uint256 public authorisedBalance;  // Only counts owner-sent ETH

    receive() external payable {
        require(msg.sender == owner, "Only owner can fund");
        totalFunded       += msg.value;
        authorisedBalance += msg.value;
        emit Funded(msg.value);
    }

    function fundERC20(uint256 amount) external onlyOwner {
        require(paymentToken != address(0), "Use ETH");
        SafeCall.safeTransferFrom(paymentToken, // FIX R6
            msg.sender, address(this), amount);
        totalFunded += amount;
        emit Funded(amount);
    }

    // ------------------------------------------------------------------ //
    //  MILESTONES
    // ------------------------------------------------------------------ //

    function addMilestone(string calldata description, uint256 amount)
        external onlyOwner whenActive {
        require(bytes(description).length > 0, "Description required");
        require(amount > 0, "Amount must be > 0");
        milestones.push(Milestone({
            description: description,
            amount:      amount,
            ownerSigned: false,
            devSigned:   false,
            released:    false,
            cancelled:   false,
            createdAt:   block.timestamp,
            releasedAt:  0
        }));
        emit MilestoneAdded(milestones.length - 1, description, amount);
    }

    function signMilestone(uint256 milestoneId) external onlyParty whenActive {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(!m.released,  "Already released");
        require(!m.cancelled, "Milestone cancelled");

        if (msg.sender == owner) {
            require(!m.ownerSigned, "Owner already signed");
            m.ownerSigned = true;
            emit MilestoneSigned(milestoneId, owner);
        } else {
            require(!m.devSigned, "Developer already signed");
            m.devSigned = true;
            emit MilestoneSigned(milestoneId, developer);
        }

        if (m.ownerSigned && m.devSigned) {
            _releaseMilestone(milestoneId);
        }
    }

    function unsignMilestone(uint256 milestoneId) external onlyParty whenActive {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(!m.released,  "Already released");
        require(!m.cancelled, "Already cancelled");

        if (msg.sender == owner) {
            require(m.ownerSigned, "Not signed");
            m.ownerSigned = false;
        } else {
            require(m.devSigned, "Not signed");
            m.devSigned = false;
        }
    }

    function _releaseMilestone(uint256 milestoneId) internal {
        Milestone storage m = milestones[milestoneId];
        uint256 amount = m.amount;
        m.released    = true;
        m.releasedAt  = block.timestamp;
        totalReleased += amount;

        if (paymentToken == address(0)) {
            // FIX: Check authorisedBalance not address(this).balance
            require(authorisedBalance >= amount, "Insufficient authorised ETH");
            authorisedBalance -= amount;
            (bool success, ) = payable(developer).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            SafeCall.safeTransfer(paymentToken, developer, amount); // FIX R6
        }
        emit MilestoneReleased(milestoneId, amount, developer);
    }

    function cancelMilestone(uint256 milestoneId) external onlyParty whenActive {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(!m.released,  "Already released");
        require(!m.cancelled, "Already cancelled");
        m.cancelled = true;
        emit MilestoneCancelled(milestoneId);
    }

    /**
     * @notice Owner claims refund of a milestone after DISPUTE_TIMEOUT
     * @dev FIX H-1: DISPUTE_TIMEOUT was declared but enforcement code was missing
     *      If developer signs but owner never responds for 90 days,
     *      OR if milestone was added but no activity for 90 days,
     *      owner can reclaim those funds
     * @param milestoneId Milestone to reclaim after timeout
     */
    function claimDisputeRefund(uint256 milestoneId) external onlyOwner {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(!m.released,  "Already released");
        require(!m.cancelled, "Already cancelled");
        // Timeout runs from milestone creation
        require(
            block.timestamp >= m.createdAt + DISPUTE_TIMEOUT,
            unicode"Dispute timeout not reached — wait 90 days from milestone creation"
        );
        m.cancelled = true;
        emit MilestoneCancelled(milestoneId);
        // Refund this milestone amount to owner
        if (paymentToken == address(0)) {
            require(authorisedBalance >= m.amount, "Insufficient balance");
            authorisedBalance -= m.amount;
            (bool success, ) = payable(owner).call{value: m.amount}("");
            require(success, "Refund failed");
        } else {
            SafeCall.safeTransfer(paymentToken, owner, m.amount); // FIX R6
        }
        emit Refunded(owner, m.amount);
    }

    // ------------------------------------------------------------------ //
    //  REFUND
    // ------------------------------------------------------------------ //

    function refundOwner() external nonReentrant onlyOwner {
        uint256 balance;
        if (paymentToken == address(0)) {
            // FIX: Use authorisedBalance not address(this).balance
            // Prevents refund of forced ETH that bypassed the receive() guard
            balance = authorisedBalance;
            require(balance > 0, "No ETH to refund");
            authorisedBalance = 0;
            (bool success, ) = payable(owner).call{value: balance}("");
            require(success, "Refund failed");
        } else {
            balance = IERC20(paymentToken).balanceOf(address(this));
            require(balance > 0, "No tokens to refund");
            SafeCall.safeTransfer(paymentToken, owner, balance); // FIX R6
        }
        emit Refunded(owner, balance);
    }

    // ------------------------------------------------------------------ //
    //  ADMIN
    // ------------------------------------------------------------------ //

    // FIX: Clear all developer signatures when developer address is changed
    // Prevents a half-signed milestone from the old developer remaining valid
    function updateDeveloper(address newDeveloper) external onlyOwner {
        require(newDeveloper != address(0), "Invalid address");
        require(newDeveloper != owner,      "Cannot be owner");

        address oldDev = developer;
        developer          = newDeveloper;
        developerConfirmed = false;
        contractActive     = false;

        // FIX: Clear all dev signatures from the old developer
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].released && !milestones[i].cancelled) {
                milestones[i].devSigned = false;
            }
        }

        emit DeveloperUpdated(oldDev, newDeveloper);
    }

    // ------------------------------------------------------------------ //
    //  VIEWS
    // ------------------------------------------------------------------ //

    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    function getMilestone(uint256 id) external view returns (
        string memory description, uint256 amount, bool ownerSigned,
        bool devSigned, bool released, bool cancelled,
        uint256 createdAt, uint256 releasedAt) {
        require(id < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[id];
        return (m.description, m.amount, m.ownerSigned, m.devSigned,
            m.released, m.cancelled, m.createdAt, m.releasedAt);
    }

    function getBalance() external view returns (uint256) {
        if (paymentToken == address(0)) return address(this).balance;
        return IERC20(paymentToken).balanceOf(address(this));
    }

    // FIX: Return correct token balance for ERC20 escrows (was returning ETH balance)
    function getStatus() external view returns (
        bool active, bool ownerReady, bool devReady,
        uint256 funded, uint256 released,
        uint256 remaining, uint256 totalMilestones) {
        uint256 balance = paymentToken == address(0)
            ? address(this).balance
            : IERC20(paymentToken).balanceOf(address(this));
        return (contractActive, ownerConfirmed, developerConfirmed,
            totalFunded, totalReleased, balance, milestones.length);
    }
}
