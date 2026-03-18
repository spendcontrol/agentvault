// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev SafeERC20
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }
}

/// @dev Lido stETH
interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

/// @dev Lido wstETH
interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
}

/// @dev Uniswap V3 SwapRouter
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title AgentVault — Multi-token treasury with spending rules for AI agents
/// @notice Deposit any ERC20 token. Optionally stake ETH via Lido. Agent spends within limits.
contract AgentVault {
    using SafeERC20 for IERC20;

    // --- Errors ---
    error OnlyOwner();
    error OnlyAgent();
    error ExceedsBudget();
    error ExceedsDailyLimit();
    error ExceedsPerTxLimit();
    error RecipientNotWhitelisted();
    error ZeroAmount();
    error ZeroAddress();
    error VaultPaused();
    error Reentrancy();
    error TokenNotSupported();

    // --- Events ---
    event Deposited(address indexed owner, address indexed token, uint256 amount);
    event Withdrawn(address indexed owner, address indexed token, uint256 amount);
    event StakedETH(address indexed owner, uint256 ethAmount, uint256 wstETHReceived);
    event AgentSpent(address indexed agent, address indexed token, address indexed to, uint256 amount, string reason);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed addr, bool status);
    event Paused(bool paused);

    // --- Expense Reports ---
    struct Expense {
        uint256 timestamp;
        address token;
        address to;
        uint256 amount;
        string reason;
    }

    Expense[] public expenses;

    // --- State ---
    address public owner;
    address public agent;

    // Spending rules (denominated in USD-equivalent via perTxLimit/dailyLimit in token amounts)
    uint256 public dailyLimit;          // per token, max agent can spend per day
    uint256 public perTxLimit;          // per token, max agent can spend per tx

    bool public paused;

    mapping(address => bool) public whitelisted;
    bool public whitelistEnabled;

    // Supported tokens — owner adds tokens they want agent to use
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    // Daily spend tracking: token => day => amount
    mapping(address => mapping(uint256 => uint256)) public dailySpent;

    // Total tracking per token
    mapping(address => uint256) public totalSpent;

    // Lido integration (optional, set to 0x0 if not needed)
    address public immutable stETH;
    address public immutable wstETH;

    // Uniswap (optional)
    address public immutable swapRouter;

    // Reentrancy guard
    uint256 private _locked = 1;

    // --- Modifiers ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert OnlyAgent();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // --- Constructor ---
    constructor(
        address _owner,
        address _agent,
        address _stETH,
        address _wstETH,
        address _swapRouter,
        uint256 _dailyLimit,
        uint256 _perTxLimit
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_agent == address(0)) revert ZeroAddress();
        owner = _owner;
        agent = _agent;
        stETH = _stETH;
        wstETH = _wstETH;
        swapRouter = _swapRouter;
        dailyLimit = _dailyLimit;
        perTxLimit = _perTxLimit;
    }

    // =============================================
    // OWNER: Deposit any ERC20
    // =============================================

    /// @notice Deposit any ERC20 token into the vault
    function deposit(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _addToken(token);

        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Stake ETH via Lido → get wstETH in the vault (optional feature)
    function stakeETH() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        require(stETH != address(0) && wstETH != address(0), "Lido not configured");

        // ETH → stETH
        uint256 stETHBefore = IERC20(stETH).balanceOf(address(this));
        ILido(stETH).submit{value: msg.value}(address(0));
        uint256 stETHReceived = IERC20(stETH).balanceOf(address(this)) - stETHBefore;

        // stETH → wstETH
        IERC20(stETH).safeApprove(wstETH, 0);
        IERC20(stETH).safeApprove(wstETH, stETHReceived);
        uint256 wstETHBefore = IERC20(wstETH).balanceOf(address(this));
        IWstETH(wstETH).wrap(stETHReceived);
        uint256 wstETHReceived = IERC20(wstETH).balanceOf(address(this)) - wstETHBefore;

        _addToken(wstETH);
        emit StakedETH(msg.sender, msg.value, wstETHReceived);
    }

    // =============================================
    // OWNER: Withdraw
    // =============================================

    /// @notice Withdraw any token from the vault
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > IERC20(token).balanceOf(address(this))) revert ExceedsBudget();
        IERC20(token).safeTransfer(owner, amount);
        emit Withdrawn(owner, token, amount);
    }

    // =============================================
    // AGENT: Spend
    // =============================================

    /// @notice Agent spends tokens with a reason
    function spend(address token, address to, uint256 amount, string calldata reason) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(token, to, amount);
        _recordSpend(token, to, amount, reason);
        IERC20(token).safeTransfer(to, amount);
        emit AgentSpent(msg.sender, token, to, amount, reason);
    }

    /// @notice Agent spends tokens (no reason)
    function spend(address token, address to, uint256 amount) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(token, to, amount);
        _recordSpend(token, to, amount, "");
        IERC20(token).safeTransfer(to, amount);
        emit AgentSpent(msg.sender, token, to, amount, "");
    }

    // =============================================
    // OWNER: Settings
    // =============================================

    function setAgent(address _agent) external onlyOwner {
        if (_agent == address(0)) revert ZeroAddress();
        emit AgentUpdated(agent, _agent);
        agent = _agent;
    }

    function setLimits(uint256 _dailyLimit, uint256 _perTxLimit) external onlyOwner {
        dailyLimit = _dailyLimit;
        perTxLimit = _perTxLimit;
        emit LimitsUpdated(_dailyLimit, _perTxLimit);
    }

    function setWhitelist(address addr, bool status) external onlyOwner {
        whitelisted[addr] = status;
        emit WhitelistUpdated(addr, status);
    }

    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    // =============================================
    // VIEW
    // =============================================

    /// @notice Get balance of a specific token in the vault
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Get all supported tokens
    function getTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /// @notice Remaining daily budget for a specific token
    function remainingDailyBudget(address token) public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[token][today];
        if (spent >= dailyLimit) return 0;
        return dailyLimit - spent;
    }

    function expenseCount() external view returns (uint256) {
        return expenses.length;
    }

    function getExpense(uint256 index) external view returns (
        uint256 timestamp, address token, address to, uint256 amount, string memory reason
    ) {
        Expense storage e = expenses[index];
        return (e.timestamp, e.token, e.to, e.amount, e.reason);
    }

    function getRecentExpenses(uint256 count) external view returns (
        uint256[] memory timestamps,
        address[] memory tokens,
        address[] memory tos,
        uint256[] memory amounts,
        string[] memory reasons
    ) {
        uint256 total = expenses.length;
        uint256 start = total > count ? total - count : 0;
        uint256 len = total - start;

        timestamps = new uint256[](len);
        tokens = new address[](len);
        tos = new address[](len);
        amounts = new uint256[](len);
        reasons = new string[](len);

        for (uint256 i = 0; i < len; i++) {
            Expense storage e = expenses[start + i];
            timestamps[i] = e.timestamp;
            tokens[i] = e.token;
            tos[i] = e.to;
            amounts[i] = e.amount;
            reasons[i] = e.reason;
        }
    }

    // =============================================
    // INTERNAL
    // =============================================

    function _validateSpend(address token, address to, uint256 amount) internal view {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (amount > IERC20(token).balanceOf(address(this))) revert ExceedsBudget();
        if (amount > perTxLimit) revert ExceedsPerTxLimit();
        uint256 today = block.timestamp / 1 days;
        if (dailySpent[token][today] + amount > dailyLimit) revert ExceedsDailyLimit();
        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();
    }

    function _recordSpend(address token, address to, uint256 amount, string memory reason) internal {
        dailySpent[token][block.timestamp / 1 days] += amount;
        totalSpent[token] += amount;
        expenses.push(Expense({
            timestamp: block.timestamp,
            token: token,
            to: to,
            amount: amount,
            reason: reason
        }));
    }

    function _addToken(address token) internal {
        if (!supportedTokens[token]) {
            supportedTokens[token] = true;
            tokenList.push(token);
        }
    }
}
