// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

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
    // --- Errors ---
    error OnlyOwner();
    error OnlyAgent();
    error OnlyOwnerOrAgent();
    error ExceedsYield();
    error ExceedsDailyLimit();
    error ExceedsPerTxLimit();
    error RecipientNotWhitelisted();
    error ZeroAmount();
    error VaultPaused();

    // --- Events ---
    event Deposited(address indexed owner, uint256 ethAmount, uint256 wstETHReceived);
    event YieldWithdrawn(address indexed agent, address indexed to, uint256 amount);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed addr, bool status);
    event Paused(bool paused);
    event PrincipalWithdrawn(address indexed owner, uint256 amount);
    event YieldSwapped(address indexed agent, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed to);

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
    function depositETH() external payable onlyOwner {
        if (msg.value == 0) revert ZeroAmount();

        // 1. Stake ETH in Lido → receive stETH
        uint256 stETHBefore = IERC20(stETH).balanceOf(address(this));
        ILido(stETH).submit{value: msg.value}(address(0));
        uint256 stETHReceived = IERC20(stETH).balanceOf(address(this)) - stETHBefore;

        // 2. Approve wstETH contract to spend our stETH
        IERC20(stETH).approve(wstETH, stETHReceived);

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
    function deposit(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(wstETH).transferFrom(msg.sender, address(this), amount);
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
    /// @notice Agent spends from available yield
    /// @param to Recipient address
    /// @param amount wstETH amount to send
    function spend(address to, uint256 amount) external onlyAgent whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > availableYield()) revert ExceedsYield();
        if (amount > perTxLimit) revert ExceedsPerTxLimit();

        uint256 today = block.timestamp / 1 days;
        if (dailySpent[today] + amount > dailyLimit) revert ExceedsDailyLimit();

        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();

        dailySpent[today] += amount;
        totalYieldSpent += amount;

        IERC20(wstETH).transfer(to, amount);
        emit YieldWithdrawn(msg.sender, to, amount);
    }

    /// @notice Agent spends yield by swapping wstETH to another token via Uniswap V3
    /// @param tokenOut The output token address
    /// @param fee The Uniswap V3 pool fee tier
    /// @param amountIn Amount of wstETH to swap
    /// @param amountOutMinimum Minimum output tokens (slippage protection)
    /// @param to Recipient of the output tokens
    function spendAndSwap(
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address to
    ) external onlyAgent whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > availableYield()) revert ExceedsYield();
        if (amountIn > perTxLimit) revert ExceedsPerTxLimit();

        uint256 today = block.timestamp / 1 days;
        if (dailySpent[today] + amountIn > dailyLimit) revert ExceedsDailyLimit();

        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();

        dailySpent[today] += amountIn;
        totalYieldSpent += amountIn;

        IERC20(wstETH).approve(swapRouter, amountIn);

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

        emit YieldSwapped(msg.sender, tokenOut, amountIn, amountOut, to);
    }

    // --- Owner: Manage ---
    function setAgent(address _agent) external onlyOwner {
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
    function withdrawPrincipal(uint256 amount) external onlyOwner {
        if (amount > principalWstETH) revert ExceedsYield();
        principalWstETH -= amount;
        IERC20(wstETH).transfer(owner, amount);
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
