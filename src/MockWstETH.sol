// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title MockWstETH — Testnet mock for wstETH with wrap/unwrap
/// @notice Simulates wstETH: wrap stETH → wstETH 1:1 (simplified, real rate varies)
contract MockWstETH {
    string public constant name = "Wrapped liquid staked Ether 2.0 (Mock)";
    string public constant symbol = "wstETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    address public stETH;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {}

    /// @notice Set stETH address (call after both mocks are deployed)
    function setStETH(address _stETH) external {
        stETH = _stETH;
    }

    /// @notice Wrap stETH → wstETH (1:1 for simplicity)
    function wrap(uint256 _stETHAmount) external returns (uint256) {
        require(stETH != address(0), "stETH not set");
        IERC20(stETH).transferFrom(msg.sender, address(this), _stETHAmount);
        // In production, wstETH amount would be less due to exchange rate
        // Mock uses 1:1 for simplicity
        balanceOf[msg.sender] += _stETHAmount;
        totalSupply += _stETHAmount;
        emit Transfer(address(0), msg.sender, _stETHAmount);
        return _stETHAmount;
    }

    /// @notice Unwrap wstETH → stETH (1:1 for simplicity)
    function unwrap(uint256 _wstETHAmount) external returns (uint256) {
        require(balanceOf[msg.sender] >= _wstETHAmount, "insufficient wstETH");
        balanceOf[msg.sender] -= _wstETHAmount;
        totalSupply -= _wstETHAmount;
        IERC20(stETH).transfer(msg.sender, _wstETHAmount);
        emit Transfer(msg.sender, address(0), _wstETHAmount);
        return _wstETHAmount;
    }

    /// @notice Anyone can mint any amount (testnet only!)
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
