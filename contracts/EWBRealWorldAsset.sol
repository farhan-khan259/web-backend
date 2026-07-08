// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBRealWorldAsset
 * @author Wayne Fyffe — Exposed Walls (EWB)
 * @notice On-chain registry anchoring the physical Banksy mural
 *         "Gorilla in a Pink Mask" (Bristol, UK, circa 2001)
 *         as a verified Real World Asset (RWA)
 * @dev TECH1 GODMODE FINAL v8 — OpenZeppelin Audit Standard
 *
 * ================================================================
 * PURPOSE
 * ================================================================
 *
 * This contract creates a legally and cryptographically verifiable
 * bridge between the physical asset and the EWB token ecosystem.
 *
 * WHY THIS MATTERS FOR AUDITORS:
 *
 * Without this contract, the $211M ecosystem value rests on
 * NFT floor prices and trait valuations — both of which auditors
 * classify as "subjective pricing models."
 *
 * With this contract, the system has:
 *   1. A verified professional appraisal ($10M–$25M FMV)
 *   2. Legal ownership chain on-chain
 *   3. IPFS-pinned documents (appraisal, provenance, insurance)
 *   4. SPV treasury address as verified custodian
 *   5. Trademark registration anchored
 *
 * This moves the collateral basis from "NFT floor price" to
 * "verified physical asset with professional appraisal" —
 * the category institutional auditors accept.
 *
 * ================================================================
 * PHYSICAL ASSET DETAILS
 * ================================================================
 *
 * Asset:       Banksy "Gorilla in a Pink Mask"
 * Location:    Bristol, UK (original site)
 * Date:        Circa 2001
 * Dimensions:  Approx 3.2ft × 5.6ft (brick mural)
 * Medium:      Spray paint on brick wall
 *
 * Appraiser:   Dr. Lori Verderame Ph.D.
 * Appraisal:   February 28, 2026
 * FMV Low:     $10,000,000 USD
 * FMV Mid:     $17,500,000 USD
 * FMV High:    $25,000,000 USD
 *
 * Legal Owner: Wayne Fyffe
 * SPV:         0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 * Trademark:   UK00003897277 — Wayne Fyffe — Class 16 — to 2033
 *
 * ================================================================
 * WHAT IS STORED ON-CHAIN
 * ================================================================
 *
 * All document hashes are IPFS CIDs (content-addressed).
 * Anyone can verify: IPFS CID → document → matches on-chain hash.
 *
 * Documents anchored:
 *   - Professional appraisal (Dr. Lori Verderame, Feb 2026)
 *   - Provenance / ownership certificate
 *   - Insurance certificate
 *   - Trademark registration certificate
 *   - Legal ownership declaration (irrevocable)
 *
 * ================================================================
 * GOVERNANCE
 * ================================================================
 *
 * Once the asset record is finalised via finalise():
 *   - Core asset data becomes IMMUTABLE
 *   - No one can change FMV, appraiser, or ownership
 *   - Documents can be added but not removed
 *   - This is the permanent on-chain record
 *
 * ================================================================
 * AUDIT REQUIRED BEFORE MAINNET DEPLOYMENT
 * ================================================================
 */

contract EWBRealWorldAsset {

    // ============================================================
    // ERRORS
    // ============================================================

    error OnlyOwner();
    error AlreadyFinalised();
    error NotFinalised();
    error ZeroAddress();
    error EmptyString();
    error EmptyHash();
    error DocumentAlreadyExists(string docType);
    error InvalidFMV();

    // ============================================================
    // ASSET CONSTANTS — set at deploy, immutable after finalise()
    // ============================================================

    /// @notice EWB ERC-721 contract linked to this physical asset
    address public constant EWB_NFT =
        0x0c06d6A17eb208A9BC7Bd698Eb6f22379209e3A4;

    /// @notice SPV Treasury — legal custodian on-chain
    address public constant SPV_TREASURY =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    /// @notice UK Trademark number
    string  public constant TRADEMARK_NUMBER = "UK00003897277";

    /// @notice Trademark class
    uint256 public constant TRADEMARK_CLASS  = 16;

    /// @notice Trademark valid until (year)
    uint256 public constant TRADEMARK_EXPIRY = 2033;

    // ============================================================
    // ASSET RECORD — mutable until finalise()
    // ============================================================

    struct AssetRecord {
        // Physical asset
        string  assetName;          // "Gorilla in a Pink Mask"
        string  assetArtist;        // "Banksy"
        string  assetLocation;      // "Bristol, UK"
        uint256 assetYear;          // 2001
        string  assetMedium;        // "Spray paint on brick wall"
        string  assetDimensions;    // "3.2ft x 5.6ft"

        // Appraisal
        string  appraiserName;      // "Dr. Lori Verderame Ph.D."
        uint256 appraisalDate;      // Unix timestamp
        uint256 fmvLow;             // $10,000,000 USD (6 dec)
        uint256 fmvMid;             // $17,500,000 USD (6 dec)
        uint256 fmvHigh;            // $25,000,000 USD (6 dec)

        // Legal ownership
        string  legalOwner;         // "Wayne Fyffe"
        address ownerAddress;       // Safe multisig address
        uint256 ownershipTransferBlock; // Block when transferred to SPV

        // Status
        bool    finalised;          // Once true — immutable
        uint256 finalisedAt;
    }

    AssetRecord public asset;

    // ============================================================
    // DOCUMENT REGISTRY
    // ============================================================

    struct Document {
        string  docType;        // "appraisal" | "provenance" | "insurance" | "trademark" | "declaration"
        string  ipfsCID;        // IPFS content identifier
        string  description;
        uint256 anchoredAt;     // Block timestamp
        address anchoredBy;     // Who anchored this document
    }

    mapping(string => Document) public documents;  // docType => Document
    string[] public documentTypes;                  // Ordered list
    mapping(string => bool) public documentExists;

    // ============================================================
    // GOVERNANCE
    // ============================================================

    address public owner; // Safe multisig — set at deploy

    // ============================================================
    // EVENTS
    // ============================================================

    event AssetRecordCreated(
        string  assetName,
        string  artist,
        uint256 fmvLow,
        uint256 fmvHigh,
        uint256 timestamp
    );
    event AssetFinalised(
        string  assetName,
        uint256 fmvMid,
        address ownerAddress,
        uint256 timestamp
    );
    event DocumentAnchored(
        string  indexed docType,
        string  ipfsCID,
        string  description,
        uint256 timestamp
    );
    event DocumentUpdated(
        string  indexed docType,
        string  oldCID,
        string  newCID,
        uint256 timestamp
    );
    event FMVUpdated(
        uint256 oldLow, uint256 oldHigh,
        uint256 newLow, uint256 newHigh,
        uint256 timestamp
    );

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier notFinalised() {
        if (asset.finalised) revert AlreadyFinalised();
        _;
    }

    modifier whenFinalised() {
        if (!asset.finalised) revert NotFinalised();
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Deploy with Safe multisig as owner
     * @dev Immediately creates the initial asset record.
     *      Call anchorDocument() for each supporting document.
     *      Call finalise() to make the record immutable.
     *
     * @param _safeMultisig Safe 2-of-3 multisig — primary governance
     */
    constructor(address _safeMultisig) {
        if (_safeMultisig == address(0)) revert ZeroAddress();
        owner = _safeMultisig;

        // Initialise asset record with known details
        asset.assetName          = "Gorilla in a Pink Mask";
        asset.assetArtist        = "Banksy";
        asset.assetLocation      = "Bristol, UK";
        asset.assetYear          = 2001;
        asset.assetMedium        = "Spray paint on brick wall";
        asset.assetDimensions    = "3.2ft x 5.6ft (approx)";
        asset.appraiserName      = "Dr. Lori Verderame Ph.D.";
        asset.appraisalDate      = 1740700800; // Feb 28 2026 UTC
        asset.fmvLow             = 10_000_000e6; // $10M in 6 dec
        asset.fmvMid             = 17_500_000e6; // $17.5M in 6 dec
        asset.fmvHigh            = 25_000_000e6; // $25M in 6 dec
        asset.legalOwner         = "Wayne Fyffe";
        asset.ownerAddress       = _safeMultisig;
        asset.ownershipTransferBlock = 24345896; // Block when transferred to SPV
        asset.finalised          = false;

        emit AssetRecordCreated(
            asset.assetName,
            asset.assetArtist,
            asset.fmvLow,
            asset.fmvHigh,
            block.timestamp
        );
    }

    // ============================================================
    // DOCUMENT ANCHORING
    // ============================================================

    /**
     * @notice Anchor a document to this RWA record via IPFS CID
     * @dev Documents are content-addressed — IPFS CID is the proof.
     *      Anyone can verify: fetch CID from IPFS, hash matches on-chain.
     *      Can be called before or after finalise().
     *      After finalise(): documents can be added but CIDs cannot change.
     *
     * Document types:
     *   "appraisal"    — Professional valuation by Dr. Lori Verderame
     *   "provenance"   — Ownership and acquisition history
     *   "insurance"    — Insurance certificate and coverage
     *   "trademark"    — UK00003897277 registration certificate
     *   "declaration"  — Irrevocable legal ownership declaration
     *   "payment"      — Lloyds Bank payment confirmation (provenance)
     *
     * @param docType    Category identifier
     * @param ipfsCID    IPFS content identifier (starts with "Qm" or "bafy")
     * @param description Human-readable description of the document
     */
    function anchorDocument(
        string calldata docType,
        string calldata ipfsCID,
        string calldata description
    )
        external
        onlyOwner
    {
        if (bytes(docType).length    == 0) revert EmptyString();
        if (bytes(ipfsCID).length    == 0) revert EmptyHash();
        if (bytes(description).length == 0) revert EmptyString();

        if (documentExists[docType]) {
            // After finalise() — cannot change existing CID
            if (asset.finalised) revert AlreadyFinalised();

            // Before finalise() — update allowed, emit UpdatedEvent
            string memory oldCID = documents[docType].ipfsCID;
            documents[docType].ipfsCID      = ipfsCID;
            documents[docType].description  = description;
            documents[docType].anchoredAt   = block.timestamp;
            documents[docType].anchoredBy   = msg.sender;
            emit DocumentUpdated(docType, oldCID, ipfsCID, block.timestamp);
        } else {
            // New document
            documents[docType] = Document({
                docType:     docType,
                ipfsCID:     ipfsCID,
                description: description,
                anchoredAt:  block.timestamp,
                anchoredBy:  msg.sender
            });
            documentTypes.push(docType);
            documentExists[docType] = true;
            emit DocumentAnchored(docType, ipfsCID, description, block.timestamp);
        }
    }

    // ============================================================
    // PRE-FINALISE UPDATES
    // ============================================================

    /**
     * @notice Update FMV range before finalisation
     * @dev Once finalised, FMV is immutable.
     *      Use if appraiser provides updated valuation.
     */
    function updateFMV(
        uint256 newLow,
        uint256 newMid,
        uint256 newHigh
    )
        external
        onlyOwner
        notFinalised
    {
        if (newLow == 0 || newMid < newLow || newHigh < newMid)
            revert InvalidFMV();

        emit FMVUpdated(
            asset.fmvLow, asset.fmvHigh,
            newLow, newHigh,
            block.timestamp
        );

        asset.fmvLow  = newLow;
        asset.fmvMid  = newMid;
        asset.fmvHigh = newHigh;
    }

    // ============================================================
    // FINALISE — makes record immutable
    // ============================================================

    /**
     * @notice Finalise the RWA record — makes core data immutable
     * @dev After finalisation:
     *      - Asset name, artist, location, year, medium cannot change
     *      - FMV range cannot change
     *      - Legal owner cannot change
     *      - Existing document CIDs cannot change
     *      - New documents CAN still be added
     *
     *      Recommended: anchor all key documents before finalising.
     *      Required documents before finalising:
     *        - "appraisal" — must be anchored
     *        - "provenance" — must be anchored
     *        - "declaration" — must be anchored
     */
    function finalise() external onlyOwner notFinalised {
        require(documentExists["appraisal"],  "Appraisal document required");
        require(documentExists["provenance"], "Provenance document required");
        require(documentExists["declaration"],"Declaration document required");

        asset.finalised   = true;
        asset.finalisedAt = block.timestamp;

        emit AssetFinalised(
            asset.assetName,
            asset.fmvMid,
            asset.ownerAddress,
            block.timestamp
        );
    }

    // ============================================================
    // VIEWS
    // ============================================================

    /**
     * @notice Get full asset record
     */
    function getAssetRecord() external view returns (AssetRecord memory) {
        return asset;
    }

    /**
     * @notice Get a specific document by type
     */
    function getDocument(string calldata docType)
        external view returns (Document memory)
    {
        return documents[docType];
    }

    /**
     * @notice Get all anchored document types
     */
    function getAllDocumentTypes()
        external view returns (string[] memory)
    {
        return documentTypes;
    }

    /**
     * @notice Get document count
     */
    function getDocumentCount() external view returns (uint256) {
        return documentTypes.length;
    }

    /**
     * @notice Verify this contract represents the given NFT contract
     */
    function isLinkedTo(address nftContract)
        external pure returns (bool)
    {
        return nftContract == EWB_NFT;
    }

    /**
     * @notice Get FMV range in USD (6 decimals)
     */
    function getFMVRange() external view returns (
        uint256 low,
        uint256 mid,
        uint256 high,
        string memory appraiser,
        uint256 appraisalDate
    ) {
        return (
            asset.fmvLow,
            asset.fmvMid,
            asset.fmvHigh,
            asset.appraiserName,
            asset.appraisalDate
        );
    }

    /**
     * @notice Check if a document type has been anchored
     */
    function hasDocument(string calldata docType)
        external view returns (bool)
    {
        return documentExists[docType];
    }

    /**
     * @notice Summary for institutional review
     */
    function getSummary() external view returns (
        string memory  name,
        string memory  artist,
        uint256        fmvLow,
        uint256        fmvHigh,
        bool           finalised,
        uint256        documentCount,
        address        spvTreasury,
        string memory  trademark
    ) {
        return (
            asset.assetName,
            asset.assetArtist,
            asset.fmvLow,
            asset.fmvHigh,
            asset.finalised,
            documentTypes.length,
            SPV_TREASURY,
            TRADEMARK_NUMBER
        );
    }
}
