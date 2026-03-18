// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentVault} from "./AgentVault.sol";

/// @title AgentVaultFactory — Create agent treasuries for any token
/// @notice One-click vault deployment. Works with USDC, WETH, wstETH, or any ERC20.
contract AgentVaultFactory {

    event VaultCreated(
        address indexed owner,
        address indexed agent,
        address indexed token,
        address vault,
        uint256 dailyLimit,
        uint256 perTxLimit
    );

    address public immutable swapRouter;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByOwner;
    mapping(address => address[]) public vaultsByAgent;

    constructor(address _swapRouter) {
        swapRouter = _swapRouter;
    }

    /// @notice Create a new AgentVault
    /// @param agent The agent's wallet address
    /// @param token The ERC20 token for this vault (e.g. USDC, WETH, wstETH)
    /// @param dailyLimit Max tokens the agent can spend per day
    /// @param perTxLimit Max tokens the agent can spend per transaction
    function createVault(
        address agent,
        address token,
        uint256 dailyLimit,
        uint256 perTxLimit
    ) external returns (address) {
        AgentVault vault = new AgentVault(
            msg.sender,
            agent,
            token,
            swapRouter,
            dailyLimit,
            perTxLimit
        );

        allVaults.push(address(vault));
        vaultsByOwner[msg.sender].push(address(vault));
        vaultsByAgent[agent].push(address(vault));

        emit VaultCreated(msg.sender, agent, token, address(vault), dailyLimit, perTxLimit);
        return address(vault);
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaultsByOwner(address owner) external view returns (address[] memory) {
        return vaultsByOwner[owner];
    }

    function getVaultsByAgent(address agent) external view returns (address[] memory) {
        return vaultsByAgent[agent];
    }
}
