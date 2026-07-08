// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/**
 * @title EWBGasPaymaster
 * @author Wayne Fyffe — Exposed Walls Banksy
 *
 * ================================================================
 * PURPOSE
 * ================================================================
 *
 * Deployed on Polygon to fund Ethereum mainnet gas fees.
 *
 * Wayne deposits MATIC here ($2 worth).
 * This contract bridges MATIC to ETH on mainnet.
 * Ballet wallet receives ETH on mainnet.
 * Ballet wallet uses ETH to deploy 24 EWB contracts.
 *
 * EWB core system remains entirely on Ethereum mainnet.
 * This contract is only a gas funding bridge.
 *
 * ================================================================
 * ADDRESSES
 * ================================================================
 *
 * Polygon MATIC:          native token
 * Polygon Bridge:         0xA0c68C638235ee32657e8f720a23ceC1bfc77C77
 * Ballet wallet mainnet:  0xc82A59594560A3010F336ebe2e9CC4794DCD46cf
 *
 * ================================================================
 */

interface IPolygonBridge {
    function depositEtherFor(address user) external payable;
}

contract EWBGasPaymaster {

    /// @notice Polygon PoS bridge — deposits ETH to mainnet
    address public constant POLYGON_BRIDGE =
        0xA0c68C638235ee32657e8f720a23ceC1bFc77C77;

    /// @notice Ballet wallet on Ethereum mainnet — receives ETH for gas
    address public constant BALLET_WALLET_MAINNET =
        0xc82A59594560A3010F336ebe2e9CC4794DCD46cf;

    /// @notice Owner — Ballet wallet on Polygon
    address public immutable owner;

    event GasFunded(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = BALLET_WALLET_MAINNET;
    }

    /**
     * @notice Fund mainnet Ballet wallet with ETH for gas
     * @dev Send MATIC to this function.
     *      MATIC bridges via Polygon PoS bridge to ETH on mainnet.
     *      ETH arrives at Ballet wallet on Ethereum mainnet.
     *      Use that ETH to deploy EWB contracts.
     */
    function fundMainnetGas() external payable onlyOwner {
        require(msg.value > 0, "Send MATIC");

        IPolygonBridge(POLYGON_BRIDGE).depositEtherFor{value: msg.value}(
            BALLET_WALLET_MAINNET
        );

        emit GasFunded(BALLET_WALLET_MAINNET, msg.value);
    }

    receive() external payable {}

    function withdraw() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "Nothing to withdraw");
        (bool ok,) = payable(owner).call{value: bal}("");
        require(ok, "Transfer failed");
    }
}
