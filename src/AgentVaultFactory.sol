// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentVault} from "./AgentVault.sol";

/// @dev EIP-1167 Minimal Proxy — deploys cheap clones (~$0.50 instead of $20)
library Clones {
    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
            if iszero(instance) { revert(0, 0) }
        }
    }
}

/// @title AgentVaultFactory — Create multi-token agent treasuries (cheap via EIP-1167 proxy)
contract AgentVaultFactory {

    event VaultCreated(
        address indexed owner,
        address indexed agent,
        address vault
    );

    address public immutable implementation;  // The master AgentVault contract
    address public immutable weth;
    address public immutable stETH;
    address public immutable wstETH;
    address public immutable swapRouter;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByOwner;
    mapping(address => address[]) public vaultsByAgent;

    constructor(address _weth, address _stETH, address _wstETH, address _swapRouter) {
        weth = _weth;
        stETH = _stETH;
        wstETH = _wstETH;
        swapRouter = _swapRouter;

        // Deploy one master implementation
        implementation = address(new AgentVault());
    }

    /// @notice Create a new AgentVault — cheap clone (~$0.50 on L1)
    function createVault(address agent) external returns (address) {
        // Clone the implementation (EIP-1167 minimal proxy)
        address vault = Clones.clone(implementation);

        // Initialize the clone
        AgentVault(vault).initialize(
            msg.sender,
            agent,
            weth,
            stETH,
            wstETH,
            swapRouter
        );

        allVaults.push(vault);
        vaultsByOwner[msg.sender].push(vault);
        vaultsByAgent[agent].push(vault);

        emit VaultCreated(msg.sender, agent, vault);
        return vault;
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
