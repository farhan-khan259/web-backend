// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// ── MOCK ERC20 (USDC substitute) ──────────────────────────────
contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name     = _name;
        symbol   = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external returns (bool)
    {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

// ── MOCK ERC721 (EWB NFT substitute) ─────────────────────────
contract MockERC721 {
    string public name;
    string public symbol;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "Already minted");
        ownerOf[tokenId] = to;
        balanceOf[to]++;
        emit Transfer(address(0), to, tokenId);
    }

    function approve(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "Not owner");
        getApproved[tokenId] = to;
        emit Approval(msg.sender, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId, msg.sender);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        // NOTE: must NOT call `this.transferFrom` — that would reset msg.sender
        // to this contract and break the operator/approval check.
        _transfer(from, to, tokenId, msg.sender);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external {
        _transfer(from, to, tokenId, msg.sender);
    }

    function _transfer(address from, address to, uint256 tokenId, address spender) internal {
        require(ownerOf[tokenId] == from, "Not owner");
        require(
            spender == from ||
            spender == getApproved[tokenId] ||
            isApprovedForAll[from][spender],
            "Not approved"
        );
        ownerOf[tokenId]     = to;
        getApproved[tokenId] = address(0);
        balanceOf[from]--;
        balanceOf[to]++;
        emit Transfer(from, to, tokenId);
    }
}

// ── MOCK ORACLE ───────────────────────────────────────────────
contract MockOracle {
    uint256 public floorPriceETH;
    uint256 public ethUSDPrice;
    bool    public useManualFloor = true;

    constructor(uint256 _floorETH, uint256 _ethUSD) {
        floorPriceETH = _floorETH;
        ethUSDPrice   = _ethUSD;
    }

    function getFloorPriceETH()  external view returns (uint256) { return floorPriceETH; }
    function getETHUSDPrice()    external view returns (uint256) { return ethUSDPrice; }

    function setFloorPrice(uint256 _floor) external { floorPriceETH = _floor; }
    function setETHUSD(uint256 _price)     external { ethUSDPrice   = _price; }
}

// ── MOCK CHAINLINK FEED ─────────────────────────────────────
contract MockChainlinkFeed {
    uint80 public roundId = 1;
    int256 public answer = 2000e8; // $2,000 ETH/USD in 8 decimals
    uint256 public startedAt = block.timestamp;
    uint256 public updatedAt = block.timestamp;
    uint80 public answeredInRound = 1;

    function latestRoundData() external view returns (
        uint80,
        int256,
        uint256,
        uint256,
        uint80
    ) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

// ── MOCK AAVE V3 ──────────────────────────────────────────────
contract MockAaveV3Pool {
    mapping(address => uint256) public supplied;
    bool public isPaused;
    uint256 public yieldRate = 35; // 3.5% expressed as per-1000
    uint256 public healthFactor = 2e18; // Default healthy HF

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(!isPaused, "Aave: paused");
        supplied[onBehalfOf] += amount;
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        require(!isPaused, "Aave: paused");
        return amount;
    }

    function borrow(address, uint256 amount, uint256, uint16, address) external {
        require(!isPaused, "Aave: paused");
    }

    function repay(address, uint256 amount, uint256, address) external returns (uint256) {
        require(!isPaused, "Aave: paused");
        return amount;
    }

    function getUserAccountData(address) external view returns (
        uint256 totalCollateral,
        uint256 totalDebt,
        uint256 availableBorrow,
        uint256 liquidationThreshold,
        uint256 ltv,
        uint256 healthFactor_
    ) {
        require(!isPaused, "Aave: paused");
        return (1e18, 0, 1e18, 8000, 7500, healthFactor);
    }

    function setHealthFactor(uint256 _hf) external { healthFactor = _hf; }
    function setPaused(bool _paused) external { isPaused = _paused; }
}

// ── MOCK LIDO ─────────────────────────────────────────────────
contract MockLido {
    uint256 public totalStaked;

    function submit(address) external payable returns (uint256) {
        totalStaked += msg.value;
        return msg.value; // 1:1 for testing
    }

    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function approve(address, uint256) external pure returns (bool) { return true; }
}

// ── MOCK WSTETH ───────────────────────────────────────────────
contract MockWstETH {
    function wrap(uint256 amount) external pure returns (uint256) {
        return amount * 9 / 10; // simulate wrapping
    }
    function unwrap(uint256 amount) external pure returns (uint256) {
        return amount * 10 / 9;
    }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

// ── MOCK WHALE VAULT (for MintingRightsVault + HarvestVault tests) ──────────
contract MockWhaleVault {
    mapping(uint256 => bool) private _locked;
    mapping(uint256 => uint8)  private _tierOf;
    mapping(uint256 => bool)  private _tierAssigned;
    mapping(address => bool)  private _harvestValid;

    function setLocked(uint256[] calldata tokenIds, bool locked) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _locked[tokenIds[i]] = locked;
        }
    }

    function setHarvestToken(address holder, bool valid) external {
        _harvestValid[holder] = valid;
    }

    function setTokenTiers(uint256[] calldata tokenIds, uint8[] calldata tiers) external {
        require(tokenIds.length == tiers.length, "Length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _tierOf[tokenIds[i]]       = tiers[i];
            _tierAssigned[tokenIds[i]] = true;
        }
    }

    function hasValidHarvestToken(address holder)
        external view returns (bool)
    {
        return _harvestValid[holder];
    }

    function validateAndRecordHarvest(address)
        external returns (bool)
    {
        return true;
    }

    function isMintingRightLocked(uint256 tokenId)
        external view returns (bool)
    {
        return _locked[tokenId];
    }

    function tokenTiers(uint256 tokenId)
        external view returns (uint8 tier, bool assigned)
    {
        tier     = _tierOf[tokenId];
        assigned = _tierAssigned[tokenId];
    }

    function getMintingLock(uint256) external view returns (
        uint256[] memory tokenIds,
        uint256 faceValueETH,
        uint256 faceValueUSD,
        uint256 lockedAt,
        uint256 expiresAt,
        bool active,
        string memory purpose
    ) {
        tokenIds     = new uint256[](0);
        faceValueETH = 315 ether;
        faceValueUSD = 850500e6;
        lockedAt     = block.timestamp;
        expiresAt    = 0;
        active       = true;
        purpose      = "credit";
    }
}

contract MockVaultOwner {
    address public immutable owner;

    constructor(address _owner) {
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
    }
}

// ── MOCK CURVE POOL (for stETH peg check) ────────────────────
contract MockCurvePool {
    uint256 public pegRatio = 1e18; // 1:1 by default

    function get_dy(int128, int128, uint256 dx)
        external view returns (uint256)
    {
        return dx * pegRatio / 1e18;
    }

    function setPegRatio(uint256 ratio) external {
        pegRatio = ratio;
    }
}
