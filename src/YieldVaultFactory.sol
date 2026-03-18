// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {YieldVault} from "./YieldVault.sol";

/// @title YieldVaultFactory — Deploy personal agent treasuries
/// @notice Anyone can create a YieldVault for their agent in one transaction
contract YieldVaultFactory {
    // --- Events ---
    event VaultCreated(
        address indexed owner,
        address indexed agent,
        address vault,
        uint256 dailyLimit,
        uint256 perTxLimit
    );

    // --- State ---
    address public immutable wstETH;
    address public immutable stETH;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByOwner;
    mapping(address => address[]) public vaultsByAgent;

    // --- Constructor ---
    constructor(address _wstETH, address _stETH) {
        wstETH = _wstETH;
        stETH = _stETH;
    }

    // --- Create Vault ---
    /// @notice Create a new YieldVault for your agent
    /// @param agent The agent's wallet address
    /// @param dailyLimit Max wstETH the agent can spend per day
    /// @param perTxLimit Max wstETH the agent can spend per transaction
    function createVault(
        address agent,
        uint256 dailyLimit,
        uint256 perTxLimit
    ) external returns (address) {
        YieldVault vault = new YieldVault(
            msg.sender,
            agent,
            wstETH,
            stETH,
            dailyLimit,
            perTxLimit
        );

        allVaults.push(address(vault));
        vaultsByOwner[msg.sender].push(address(vault));
        vaultsByAgent[agent].push(address(vault));

        emit VaultCreated(msg.sender, agent, address(vault), dailyLimit, perTxLimit);
        return address(vault);
    }

    // --- Views ---
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
