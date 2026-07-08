// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWB Trademark Legal Bridge
 * @notice On-chain anchor binding UK trademark UK00003897277
 *         to the SPV Treasury smart contract
 *
 * ================================================================
 * THE TRADEMARK ISOLATION PROBLEM
 * ================================================================
 *
 * UK trademark UK00003897277 is a legally registered IP asset
 * held by Wayne Fyffe at the UK Intellectual Property Office.
 *
 * The problem: trademark is off-chain. Liquidation routers have
 * zero jurisdiction over physical legal IP assets. If Layer 3
 * Hard Floor triggers, routers can seize on-chain tokens but
 * CANNOT enforce transfer of the trademark.
 *
 * ================================================================
 * SOLUTION: THREE-LAYER LEGAL BRIDGE
 * ================================================================
 *
 * Bridge 1 — IPFS Documentation Anchor
 *   Trademark certificate, legal agreements, and licence docs
 *   stored as IPFS hashes in this contract. Creates immutable
 *   provenance record linking trademark to SPV address.
 *
 * Bridge 2 — Royalty Revenue Router
 *   Any royalty income from trademark licensing routes through
 *   the SPV treasury address, creating a financial link between
 *   the IP asset and the on-chain ecosystem.
 *
 * Bridge 3 — Legal Wrapper Declaration
 *   Owner declares the SPV treasury as the designated
 *   beneficiary of trademark proceeds. Stored immutably on-chain
 *   as an irrevocable declaration of intent.
 *
 * NOTE: This contract does NOT give smart contracts legal power
 * over the trademark. It creates the strongest possible
 * evidentiary and financial link between the IP and the chain.
 * Full enforcement still requires legal proceedings.
 *
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

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



contract EWBTrademarkBridge {

    // ============================================================
    // TRADEMARK CONSTANTS — IMMUTABLE
    // ============================================================

    string  public constant TRADEMARK_NUMBER    = "UK00003897277";
    string  public constant TRADEMARK_OWNER     = "Wayne Fyffe";
    string  public constant TRADEMARK_CLASS     = "Class 16";
    uint256 public constant TRADEMARK_FILED     = 1680652800; // 05 Apr 2023 UTC
    uint256 public constant TRADEMARK_REGISTERED= 1688083200; // 30 Jun 2023 UTC
    uint256 public constant TRADEMARK_EXPIRY    = 1996531200; // 05 Apr 2033 UTC

    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    // ============================================================
    // BRIDGE 1 — IPFS DOCUMENTATION ANCHORS
    // ============================================================

    // IPFS hashes of legal documents — set by owner after upload
    string  public ipfsCertificate;      // Trademark registration certificate
    string  public ipfsLicenceAgreement; // Trademark licence agreement
    string  public ipfsLegalOpinion;     // Solicitor legal bridge opinion
    string  public ipfsSPVAgreement;     // SPV beneficial ownership docs

    bool    public certificateAnchored;
    bool    public licenceAnchored;
    bool    public legalOpinionAnchored;
    bool    public spvAgreementAnchored;

    // ============================================================
    // BRIDGE 2 — ROYALTY REVENUE ROUTER
    // ============================================================

    uint256 public totalRoyaltiesReceived;
    uint256 public totalRoyaltiesRouted;

    struct RoyaltyPayment {
        address payer;
        uint256 amount;
        string  licence;    // licence reference
        uint256 timestamp;
    }
    RoyaltyPayment[] public royaltyHistory;

    // ============================================================
    // BRIDGE 3 — LEGAL WRAPPER DECLARATION
    // ============================================================

    // Owner's irrevocable on-chain declaration
    string  public legalDeclaration;
    uint256 public declarationTimestamp;
    bool    public declarationMade;

    // ============================================================
    // STATE
    // ============================================================

    address public owner;
    bool    public bridgeActive;

    // ============================================================
    // EVENTS
    // ============================================================

    event DocumentAnchored(string docType, string ipfsHash, uint256 timestamp);
    event RoyaltyReceived(address payer, uint256 amount, string licence);
    event RoyaltyRouted(uint256 amount, address spv);
    event DeclarationMade(string declaration, uint256 timestamp);
    event BridgeActivated(uint256 timestamp);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyOwner() { require(msg.sender == owner, "Only owner"); _; }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor() { owner = msg.sender; }

    // ============================================================
    // BRIDGE 1 — ANCHOR DOCUMENTS
    // ============================================================

    /**
     * @notice Anchor trademark certificate IPFS hash on-chain
     * @param ipfsHash IPFS CID of the trademark certificate PDF
     */
    function anchorCertificate(string calldata ipfsHash) external onlyOwner {
        require(!certificateAnchored, "Already anchored");
        require(bytes(ipfsHash).length > 0, "Invalid hash");
        ipfsCertificate    = ipfsHash;
        certificateAnchored = true;
        emit DocumentAnchored("TRADEMARK_CERTIFICATE", ipfsHash, block.timestamp);
    }

    /**
     * @notice Anchor licence agreement IPFS hash
     * @param ipfsHash IPFS CID of the licence agreement
     */
    function anchorLicenceAgreement(string calldata ipfsHash) external onlyOwner {
        require(!licenceAnchored, "Already anchored");
        ipfsLicenceAgreement = ipfsHash;
        licenceAnchored      = true;
        emit DocumentAnchored("LICENCE_AGREEMENT", ipfsHash, block.timestamp);
    }

    /**
     * @notice Anchor solicitor legal bridge opinion
     * @param ipfsHash IPFS CID of the legal opinion
     */
    function anchorLegalOpinion(string calldata ipfsHash) external onlyOwner {
        require(!legalOpinionAnchored, "Already anchored");
        ipfsLegalOpinion      = ipfsHash;
        legalOpinionAnchored  = true;
        emit DocumentAnchored("LEGAL_OPINION", ipfsHash, block.timestamp);
    }

    /**
     * @notice Anchor SPV beneficial ownership agreement
     * @param ipfsHash IPFS CID of the SPV agreement
     */
    function anchorSPVAgreement(string calldata ipfsHash) external onlyOwner {
        require(!spvAgreementAnchored, "Already anchored");
        ipfsSPVAgreement      = ipfsHash;
        spvAgreementAnchored  = true;
        emit DocumentAnchored("SPV_AGREEMENT", ipfsHash, block.timestamp);
    }

    // ============================================================
    // BRIDGE 2 — ROYALTY ROUTING
    // ============================================================

    /**
     * @notice Receive royalty payment and route to SPV treasury
     * @dev Any licensee paying royalties calls this function
     *      Payment routes directly to SPV treasury address
     * @param token Payment token (USDC)
     * @param amount Royalty amount
     * @param licenceRef Licence reference number
     */
    function receiveRoyalty(
        address token,
        uint256 amount,
        string calldata licenceRef
    ) external {
        require(amount > 0, "No royalty amount");

        // Transfer from payer
        require(
            IERC20(token).transferFrom(msg.sender, address(this), amount),
            "Royalty transfer failed"
        );

        totalRoyaltiesReceived += amount;

        royaltyHistory.push(RoyaltyPayment({
            payer:     msg.sender,
            amount:    amount,
            licence:   licenceRef,
            timestamp: block.timestamp
        }));

        emit RoyaltyReceived(msg.sender, amount, licenceRef);

        // Route to SPV treasury
        SafeCall.safeTransfer(token, SPV_TREASURY, amount); // FIX R6

        totalRoyaltiesRouted += amount;
        emit RoyaltyRouted(amount, SPV_TREASURY);
    }

    // ============================================================
    // BRIDGE 3 — LEGAL DECLARATION
    // ============================================================

    /**
     * @notice Make irrevocable on-chain declaration
     * @dev Owner declares SPV as trademark beneficiary
     *      This is a one-time irrevocable statement
     * @param declaration The legal declaration text
     */
    function makeDeclaration(string calldata declaration) external onlyOwner {
        require(!declarationMade, "Declaration already made");
        require(bytes(declaration).length > 0, "Empty declaration");

        legalDeclaration     = declaration;
        declarationTimestamp = block.timestamp;
        declarationMade      = true;

        emit DeclarationMade(declaration, block.timestamp);
    }

    // ============================================================
    // ACTIVATE BRIDGE
    // ============================================================

    /**
     * @notice Activate bridge — requires all three bridges in place
     */
    function activateBridge() external onlyOwner {
        require(certificateAnchored,  "Certificate not anchored");
        require(licenceAnchored,      "Licence not anchored");
        require(declarationMade,      "Declaration not made");
        bridgeActive = true;
        emit BridgeActivated(block.timestamp);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get full bridge status
     */
    function getBridgeStatus() external view returns (
        bool certAnchored,
        bool licenceAnch,
        bool legalOpinionAnch,
        bool spvAgreementAnch,
        bool declarationSet,
        bool active,
        uint256 royaltiesTotal,
        uint256 daysUntilExpiry
    ) {
        uint256 expiry = TRADEMARK_EXPIRY > block.timestamp
            ? (TRADEMARK_EXPIRY - block.timestamp) / 86400
            : 0;
        return (
            certificateAnchored,
            licenceAnchored,
            legalOpinionAnchored,
            spvAgreementAnchored,
            declarationMade,
            bridgeActive,
            totalRoyaltiesReceived,
            expiry
        );
    }

    /**
     * @notice Days until trademark renewal required
     */
    function daysUntilRenewal() external view returns (uint256) {
        if (TRADEMARK_EXPIRY <= block.timestamp) return 0;
        return (TRADEMARK_EXPIRY - block.timestamp) / 86400;
    }

    /**
     * @notice Get royalty history count
     */
    function getRoyaltyCount() external view returns (uint256) {
        return royaltyHistory.length;
    }

    // ============================================================
    // ADMIN
    // ============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid");
        owner = newOwner;
    }
}
