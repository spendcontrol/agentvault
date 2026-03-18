// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev SafeERC20 — handles non-standard tokens (USDT doesn't return bool)
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

/// @title AgentVault — Treasury with spending rules for AI agents
/// @notice Deposit any token. Set spending limits. Agent operates within rules.
/// @dev Supports ETH, USDC, WETH, wstETH, or any ERC20 as the vault token.
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

    // --- Events ---
    event Deposited(address indexed owner, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event AgentSpent(address indexed agent, address indexed to, uint256 amount, string reason);
    event AgentSwapped(address indexed agent, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed to, string reason);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed addr, bool status);
    event Paused(bool paused);

    // --- Expense Reports ---
    struct Expense {
        uint256 timestamp;
        address to;
        uint256 amount;
        string reason;
    }

    Expense[] public expenses;

    // --- State ---
    address public owner;
    address public agent;
    IERC20 public immutable token;          // The vault's token (USDC, WETH, wstETH, etc.)
    address public immutable swapRouter;     // Uniswap V3 router (0x0 if no swaps needed)

    uint256 public totalDeposited;
    uint256 public totalSpent;

    uint256 public dailyLimit;
    uint256 public perTxLimit;

    bool public paused;

    mapping(address => bool) public whitelisted;
    bool public whitelistEnabled;

    mapping(uint256 => uint256) public dailySpent;

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
        address _token,
        address _swapRouter,
        uint256 _dailyLimit,
        uint256 _perTxLimit
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_agent == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        owner = _owner;
        agent = _agent;
        token = IERC20(_token);
        swapRouter = _swapRouter;
        dailyLimit = _dailyLimit;
        perTxLimit = _perTxLimit;
    }

    // =============================================
    // OWNER: Deposit & Withdraw
    // =============================================

    /// @notice Deposit tokens into the vault
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw tokens (owner can always exit)
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > token.balanceOf(address(this))) revert ExceedsBudget();
        totalDeposited = totalDeposited > amount ? totalDeposited - amount : 0;
        token.safeTransfer(owner, amount);
        emit Withdrawn(owner, amount);
    }

    // =============================================
    // AGENT: Spend
    // =============================================

    /// @notice Agent spends tokens with a reason
    function spend(address to, uint256 amount, string calldata reason) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(to, amount);
        _recordSpend(to, amount, reason);
        token.safeTransfer(to, amount);
        emit AgentSpent(msg.sender, to, amount, reason);
    }

    /// @notice Agent spends tokens (no reason)
    function spend(address to, uint256 amount) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(to, amount);
        _recordSpend(to, amount, "");
        token.safeTransfer(to, amount);
        emit AgentSpent(msg.sender, to, amount, "");
    }

    /// @notice Agent swaps vault token → another token via Uniswap, with reason
    function spendAndSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to,
        string calldata reason
    ) external onlyAgent whenNotPaused nonReentrant returns (uint256 amountOut) {
        _validateSpend(to, amountIn);
        _recordSpend(to, amountIn, reason);
        amountOut = _swap(tokenOut, fee, amountIn, amountOutMinimum, to);
        emit AgentSwapped(msg.sender, tokenOut, amountIn, amountOut, to, reason);
    }

    /// @notice Agent swaps vault token → another token via Uniswap (no reason)
    function spendAndSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to
    ) external onlyAgent whenNotPaused nonReentrant returns (uint256 amountOut) {
        _validateSpend(to, amountIn);
        _recordSpend(to, amountIn, "");
        amountOut = _swap(tokenOut, fee, amountIn, amountOutMinimum, to);
        emit AgentSwapped(msg.sender, tokenOut, amountIn, amountOut, to, "");
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

    /// @notice How much the agent can spend right now
    function availableBudget() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice How much the agent can still spend today
    function remainingDailyBudget() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[today];
        if (spent >= dailyLimit) return 0;
        return dailyLimit - spent;
    }

    function getStats() external view returns (
        uint256 _balance,
        uint256 _totalDeposited,
        uint256 _totalSpent,
        uint256 _availableBudget,
        uint256 _remainingDailyBudget
    ) {
        return (
            token.balanceOf(address(this)),
            totalDeposited,
            totalSpent,
            availableBudget(),
            remainingDailyBudget()
        );
    }

    function expenseCount() external view returns (uint256) {
        return expenses.length;
    }

    function getExpense(uint256 index) external view returns (
        uint256 timestamp, address to, uint256 amount, string memory reason
    ) {
        Expense storage e = expenses[index];
        return (e.timestamp, e.to, e.amount, e.reason);
    }

    function getRecentExpenses(uint256 count) external view returns (
        uint256[] memory timestamps,
        address[] memory tos,
        uint256[] memory amounts,
        string[] memory reasons
    ) {
        uint256 total = expenses.length;
        uint256 start = total > count ? total - count : 0;
        uint256 len = total - start;

        timestamps = new uint256[](len);
        tos = new address[](len);
        amounts = new uint256[](len);
        reasons = new string[](len);

        for (uint256 i = 0; i < len; i++) {
            Expense storage e = expenses[start + i];
            timestamps[i] = e.timestamp;
            tos[i] = e.to;
            amounts[i] = e.amount;
            reasons[i] = e.reason;
        }
    }

    // =============================================
    // INTERNAL
    // =============================================

    function _validateSpend(address to, uint256 amount) internal view {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > token.balanceOf(address(this))) revert ExceedsBudget();
        if (amount > perTxLimit) revert ExceedsPerTxLimit();
        uint256 today = block.timestamp / 1 days;
        if (dailySpent[today] + amount > dailyLimit) revert ExceedsDailyLimit();
        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();
    }

    function _recordSpend(address to, uint256 amount, string memory reason) internal {
        dailySpent[block.timestamp / 1 days] += amount;
        totalSpent += amount;
        expenses.push(Expense({
            timestamp: block.timestamp,
            to: to,
            amount: amount,
            reason: reason
        }));
    }

    function _swap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to
    ) internal returns (uint256 amountOut) {
        require(swapRouter != address(0), "No swap router");
        IERC20(address(token)).safeApprove(swapRouter, 0);
        IERC20(address(token)).safeApprove(swapRouter, amountIn);

        amountOut = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: tokenOut,
                fee: fee,
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
