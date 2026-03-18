// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentVault} from "./AgentVault.sol";

/// @title AgentVaultFactory — Create multi-token agent treasuries
contract AgentVaultFactory {

    event VaultCreated(
        address indexed owner,
        address indexed agent,
        address vault
    );

    address public immutable stETH;
    address public immutable wstETH;
    address public immutable swapRouter;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByOwner;
    mapping(address => address[]) public vaultsByAgent;

    constructor(address _stETH, address _wstETH, address _swapRouter) {
        stETH = _stETH;
        wstETH = _wstETH;
        swapRouter = _swapRouter;
    }

    /// @notice Create a new AgentVault
    /// @param agent The agent's wallet address
    /// @param dailyLimit Max tokens agent can spend per day (per token)
    /// @param perTxLimit Max tokens agent can spend per transaction
    function createVault(
        address agent,
        uint256 dailyLimit,
        uint256 perTxLimit
    ) external returns (address) {
        AgentVault vault = new AgentVault(
            msg.sender,
            agent,
            stETH,
            wstETH,
            swapRouter,
            dailyLimit,
            perTxLimit
        );

        allVaults.push(address(vault));
        vaultsByOwner[msg.sender].push(address(vault));
        vaultsByAgent[agent].push(address(vault));

        emit VaultCreated(msg.sender, agent, address(vault));
        return address(vault);
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaultsByOwner(address _owner) external view returns (address[] memory) {
        return vaultsByOwner[_owner];
    }

    function getVaultsByAgent(address _agent) external view returns (address[] memory) {
        return vaultsByAgent[_agent];
    }
}
