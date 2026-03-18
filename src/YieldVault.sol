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

/// @dev Lido stETH — submit ETH, receive stETH
interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

/// @dev Lido wstETH — wrap stETH into non-rebasing wstETH
interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
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

/// @title YieldVault — Operating budget protocol for AI agents
/// @notice Stake ETH via Lido. Agent lives off the yield. Principal stays untouched.
/// @dev Uses wstETH internally for simpler accounting (no rebasing)
contract YieldVault {
    using SafeERC20 for IERC20;

    // --- Errors ---
    error OnlyOwner();
    error OnlyAgent();
    error OnlyOwnerOrAgent();
    error ExceedsYield();
    error ExceedsDailyLimit();
    error ExceedsPerTxLimit();
    error RecipientNotWhitelisted();
    error ZeroAmount();
    error ZeroAddress();
    error VaultPaused();
    error Reentrancy();

    // --- Events ---
    event Deposited(address indexed owner, uint256 ethAmount, uint256 wstETHReceived);
    event YieldWithdrawn(address indexed agent, address indexed to, uint256 amount, string reason);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed addr, bool status);
    event Paused(bool paused);
    event PrincipalWithdrawn(address indexed owner, uint256 amount);
    event YieldSwapped(address indexed agent, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed to, string reason);

    // --- Expense Reports ---
    struct ExpenseReport {
        uint256 timestamp;
        address to;
        uint256 amount;
        string reason;
        bytes32 txHash; // not set in contract, but useful for off-chain tracking
    }

    ExpenseReport[] public expenses;
    uint256 public expenseCount;

    // --- State ---
    address public owner;
    address public agent;

    uint256 public principalWstETH;    // wstETH deposited (principal, locked from agent)
    uint256 public totalYieldSpent;     // cumulative yield spent by agent

    uint256 public dailyLimit;          // max wstETH agent can spend per day
    uint256 public perTxLimit;          // max wstETH agent can spend per transaction

    bool public paused;

    // Whitelist: addresses agent is allowed to send to (0 = any)
    mapping(address => bool) public whitelisted;
    bool public whitelistEnabled;

    // Daily spend tracking
    mapping(uint256 => uint256) public dailySpent; // day => amount spent

    // Lido contracts on Base (will be set via constructor for flexibility)
    address public wstETH;
    address public stETH;

    // Uniswap V3 SwapRouter
    address public swapRouter;

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
        address _wstETH,
        address _stETH,
        address _swapRouter,
        uint256 _dailyLimit,
        uint256 _perTxLimit
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_agent == address(0)) revert ZeroAddress();
        if (_wstETH == address(0)) revert ZeroAddress();
        if (_stETH == address(0)) revert ZeroAddress();
        owner = _owner;
        agent = _agent;
        wstETH = _wstETH;
        stETH = _stETH;
        swapRouter = _swapRouter;
        dailyLimit = _dailyLimit;
        perTxLimit = _perTxLimit;
    }

    // --- Owner: Deposit ---

    /// @notice Deposit ETH — auto-stakes via Lido → stETH → wstETH
    /// @dev This is the main entry point. Human sends ETH, contract handles everything.
    function depositETH() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        // 1. Stake ETH in Lido → receive stETH
        uint256 stETHBefore = IERC20(stETH).balanceOf(address(this));
        ILido(stETH).submit{value: msg.value}(address(0));
        uint256 stETHReceived = IERC20(stETH).balanceOf(address(this)) - stETHBefore;

        // 2. Approve wstETH contract to spend our stETH (reset first to handle non-zero allowance)
        IERC20(stETH).safeApprove(wstETH, 0);
        IERC20(stETH).safeApprove(wstETH, stETHReceived);

        // 3. Wrap stETH → wstETH
        uint256 wstETHBefore = IERC20(wstETH).balanceOf(address(this));
        IWstETH(wstETH).wrap(stETHReceived);
        uint256 wstETHReceived = IERC20(wstETH).balanceOf(address(this)) - wstETHBefore;

        // 4. Record principal
        principalWstETH += wstETHReceived;
        emit Deposited(msg.sender, msg.value, wstETHReceived);
    }

    /// @notice Deposit wstETH directly (for users who already have wstETH)
    /// @param amount Amount of wstETH to deposit
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(wstETH).safeTransferFrom(msg.sender, address(this), amount);
        principalWstETH += amount;
        emit Deposited(msg.sender, amount, amount);
    }

    // --- View: Available Yield ---
    /// @notice Calculate how much yield is available for the agent
    /// @return available wstETH amount the agent can spend
    function availableYield() public view returns (uint256) {
        uint256 currentBalance = IERC20(wstETH).balanceOf(address(this));
        if (currentBalance <= principalWstETH) return 0;
        return currentBalance - principalWstETH;
    }

    /// @notice How much the agent can still spend today
    function remainingDailyBudget() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[today];
        if (spent >= dailyLimit) return 0;
        return dailyLimit - spent;
    }

    // --- Agent: Spend Yield ---
    /// @notice Agent spends from available yield with a reason
    /// @param to Recipient address
    /// @param amount wstETH amount to send
    /// @param reason Why the agent is spending (stored on-chain)
    function spend(address to, uint256 amount, string calldata reason) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(to, amount);

        dailySpent[block.timestamp / 1 days] += amount;
        totalYieldSpent += amount;

        expenses.push(ExpenseReport({
            timestamp: block.timestamp,
            to: to,
            amount: amount,
            reason: reason,
            txHash: bytes32(0)
        }));
        expenseCount++;

        IERC20(wstETH).safeTransfer(to, amount);
        emit YieldWithdrawn(msg.sender, to, amount, reason);
    }

    /// @notice Agent spends without a reason (backwards compatible)
    function spend(address to, uint256 amount) external onlyAgent whenNotPaused nonReentrant {
        _validateSpend(to, amount);

        dailySpent[block.timestamp / 1 days] += amount;
        totalYieldSpent += amount;

        expenses.push(ExpenseReport({
            timestamp: block.timestamp,
            to: to,
            amount: amount,
            reason: "",
            txHash: bytes32(0)
        }));
        expenseCount++;

        IERC20(wstETH).safeTransfer(to, amount);
        emit YieldWithdrawn(msg.sender, to, amount, "");
    }

    /// @notice Internal validation for spend
    function _validateSpend(address to, uint256 amount) internal view {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > availableYield()) revert ExceedsYield();
        if (amount > perTxLimit) revert ExceedsPerTxLimit();
        uint256 today = block.timestamp / 1 days;
        if (dailySpent[today] + amount > dailyLimit) revert ExceedsDailyLimit();
        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();
    }

    /// @notice Get expense report by index
    function getExpense(uint256 index) external view returns (
        uint256 timestamp, address to, uint256 amount, string memory reason
    ) {
        ExpenseReport storage e = expenses[index];
        return (e.timestamp, e.to, e.amount, e.reason);
    }

    /// @notice Get recent expenses (last N)
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
            ExpenseReport storage e = expenses[start + i];
            timestamps[i] = e.timestamp;
            tos[i] = e.to;
            amounts[i] = e.amount;
            reasons[i] = e.reason;
        }
    }

    /// @notice Agent spends yield by swapping via Uniswap V3, with reason
    function spendAndSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to,
        string calldata reason
    ) external onlyAgent whenNotPaused nonReentrant returns (uint256 amountOut) {
        amountOut = _executeSwap(tokenOut, fee, amountIn, amountOutMinimum, to);

        expenses.push(ExpenseReport({
            timestamp: block.timestamp,
            to: to,
            amount: amountIn,
            reason: reason,
            txHash: bytes32(0)
        }));
        expenseCount++;

        emit YieldSwapped(msg.sender, tokenOut, amountIn, amountOut, to, reason);
    }

    /// @notice Agent spends yield by swapping via Uniswap V3 (no reason)
    function spendAndSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to
    ) external onlyAgent whenNotPaused nonReentrant returns (uint256 amountOut) {
        amountOut = _executeSwap(tokenOut, fee, amountIn, amountOutMinimum, to);

        expenses.push(ExpenseReport({
            timestamp: block.timestamp,
            to: to,
            amount: amountIn,
            reason: "",
            txHash: bytes32(0)
        }));
        expenseCount++;

        emit YieldSwapped(msg.sender, tokenOut, amountIn, amountOut, to, "");
    }

    function _executeSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to
    ) internal returns (uint256 amountOut) {
        _validateSpend(to, amountIn);

        dailySpent[block.timestamp / 1 days] += amountIn;
        totalYieldSpent += amountIn;

        IERC20(wstETH).safeApprove(swapRouter, 0);
        IERC20(wstETH).safeApprove(swapRouter, amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: wstETH,
            tokenOut: tokenOut,
            fee: fee,
            recipient: to,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(swapRouter).exactInputSingle(params);
    }

    // --- Owner: Manage ---
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

    /// @notice Owner can withdraw principal (emergency / exit)
    function withdrawPrincipal(uint256 amount) external onlyOwner nonReentrant {
        if (amount > principalWstETH) revert ExceedsYield();
        principalWstETH -= amount;
        IERC20(wstETH).safeTransfer(owner, amount);
        emit PrincipalWithdrawn(owner, amount);
    }

    // --- View: Stats ---
    function getStats() external view returns (
        uint256 _principal,
        uint256 _currentBalance,
        uint256 _availableYield,
        uint256 _totalYieldSpent,
        uint256 _remainingDailyBudget
    ) {
        return (
            principalWstETH,
            IERC20(wstETH).balanceOf(address(this)),
            availableYield(),
            totalYieldSpent,
            remainingDailyBudget()
        );
    }
}
