// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title ReentrantERC20
 * @notice Malicious ERC20 that attempts reentrancy on transfer
 * @dev Used to verify nonReentrant guards are correctly placed
 */
contract ReentrantERC20 {
    string  public name     = "Reentrant USDC";
    string  public symbol   = "rUSDC";
    uint8   public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;      // Contract to reenter
    bytes   public reentrantCall; // Calldata to replay
    bool    public attackActive;
    bool    private _inCallback;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function setReentrantTarget(
        address _target,
        bytes calldata _call
    ) external {
        target        = _target;
        reentrantCall = _call;
        attackActive  = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        external returns (bool)
    {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        return _transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount)
        internal returns (bool)
    {
        require(balanceOf[from] >= amount, "Insufficient");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);

        // Attempt reentrancy on outgoing transfer
        if (attackActive && !_inCallback && to == target) {
            _inCallback = true;
            (bool ok, ) = target.call(reentrantCall);
            // We don't revert if call fails — we just check the guard caught it
            _inCallback = false;
            ok; // suppress unused warning
        }
        return true;
    }
}
