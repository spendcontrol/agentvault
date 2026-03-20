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

/// @dev WETH — wrap/unwrap ETH
interface IWETH {
    function deposit() external payable;
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
    event StakedETH(address indexed owner, uint256 ethAmount, uint256 wstETHReceived, bool yieldOnly);
    event AgentSpent(address indexed agent, address indexed token, address indexed to, uint256 amount, string reason);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event TokenLimitsUpdated(address indexed token, uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed addr, bool status);
    event Paused(bool paused);
    event YieldHarvested(uint256 amount, uint256 totalSpendable);

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

    // Spending rules — per token
    mapping(address => uint256) public dailyLimit;    // token => max per day
    mapping(address => uint256) public perTxLimit;    // token => max per tx
    uint256 public defaultDailyLimit;                  // fallback for tokens without custom limit
    uint256 public defaultPerTxLimit;                  // fallback for tokens without custom limit

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

    // WETH for ETH deposits
    address public weth;

    // Lido integration (optional, set to 0x0 if not needed)
    address public stETH;     // stETH is a rebase token — balance grows as yield accrues
    address public wstETH;    // kept for compatibility

    // Yield tracking for staked ETH (stETH)
    uint256 public stakedPrincipal;     // stETH amount recorded at deposit (doesn't grow)
    uint256 public harvestedYield;      // stETH yield claimed via harvestYield()
    uint256 public yieldSpent;          // stETH yield already spent by agent
    uint256 public lastHarvestTime;     // timestamp of last harvest
    bool public yieldOnly;              // if true, agent can only spend harvested yield from stETH

    // Uniswap (optional)
    address public swapRouter;

    // Initializable guard
    bool private _initialized;

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

    // --- Initialize (used by proxy clones instead of constructor) ---
    function initialize(
        address _owner,
        address _agent,
        address _weth,
        address _stETH,
        address _wstETH,
        address _swapRouter
    ) external {
        require(!_initialized, "Already initialized");
        if (_owner == address(0)) revert ZeroAddress();
        if (_agent == address(0)) revert ZeroAddress();
        _initialized = true;
        _locked = 1;
        owner = _owner;
        agent = _agent;
        weth = _weth;
        stETH = _stETH;
        wstETH = _wstETH;
        swapRouter = _swapRouter;
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

    /// @notice Deposit ETH — auto-wraps to WETH and deposits into vault
    function depositETH() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        require(weth != address(0), "WETH not configured");

        IWETH(weth).deposit{value: msg.value}();
        _addToken(weth);

        emit Deposited(msg.sender, weth, msg.value);
    }

    /// @notice Stake ETH via Lido → stETH stays in vault, yield accrues via rebase
    /// @param _yieldOnly If true, agent can only spend harvested yield (principal locked)
    function stakeETH(bool _yieldOnly) external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        require(stETH != address(0), "Lido not configured");

        // ETH → stETH (stETH is rebase token, balance grows over time)
        uint256 stETHBefore = IERC20(stETH).balanceOf(address(this));
        ILido(stETH).submit{value: msg.value}(address(0));
        uint256 stETHReceived = IERC20(stETH).balanceOf(address(this)) - stETHBefore;

        stakedPrincipal += stETHReceived;

        if (_yieldOnly) {
            yieldOnly = true;
        }

        _addToken(stETH);
        emit StakedETH(msg.sender, msg.value, stETHReceived, _yieldOnly);
    }

    // =============================================
    // YIELD: Harvest & track
    // =============================================

    /// @notice Unharvested yield = stETH balance growth since principal was recorded
    function pendingYield() public view returns (uint256) {
        if (stETH == address(0)) return 0;
        uint256 balance = IERC20(stETH).balanceOf(address(this));
        uint256 principal = stakedPrincipal;
        // Available = total stETH - principal - yield already harvested but not yet spent
        uint256 accountedFor = principal + (harvestedYield - yieldSpent);
        if (balance <= accountedFor) return 0;
        return balance - accountedFor;
    }

    /// @notice Harvest accrued yield — callable once per day by anyone
    /// @dev Makes yield available for the agent to spend
    function harvestYield() external nonReentrant {
        require(stETH != address(0), "No staking active");
        require(block.timestamp >= lastHarvestTime + 1 days, "Already harvested today");

        uint256 pending = pendingYield();
        require(pending > 0, "No yield to harvest");

        harvestedYield += pending;
        lastHarvestTime = block.timestamp;

        emit YieldHarvested(pending, harvestedYield - yieldSpent);
    }

    /// @notice How much harvested yield the agent can still spend
    function spendableYield() public view returns (uint256) {
        return harvestedYield - yieldSpent;
    }

    /// @notice Owner can withdraw staked principal (stETH)
    function withdrawPrincipal(uint256 amount) external onlyOwner nonReentrant {
        if (amount > stakedPrincipal) revert ExceedsBudget();
        stakedPrincipal -= amount;
        IERC20(stETH).safeTransfer(owner, amount);
        emit Withdrawn(owner, stETH, amount);
    }

    /// @notice Owner toggles yield-only mode
    function setYieldOnly(bool _yieldOnly) external onlyOwner {
        yieldOnly = _yieldOnly;
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

    /// @notice Agent spends tokens with a reason (reason is mandatory)
    function spend(address token, address to, uint256 amount, string calldata reason) external onlyAgent whenNotPaused nonReentrant {
        require(bytes(reason).length > 0, "Reason required");
        _validateSpend(token, to, amount);
        _recordSpend(token, to, amount, reason);
        IERC20(token).safeTransfer(to, amount);
        emit AgentSpent(msg.sender, token, to, amount, reason);
    }

    // =============================================
    // OWNER: Settings
    // =============================================

    function setAgent(address _agent) external onlyOwner {
        if (_agent == address(0)) revert ZeroAddress();
        emit AgentUpdated(agent, _agent);
        agent = _agent;
    }

    /// @notice Set limits for a specific token (0 = use default)
    function setTokenLimits(address token, uint256 _dailyLimit, uint256 _perTxLimit) external onlyOwner {
        dailyLimit[token] = _dailyLimit;
        perTxLimit[token] = _perTxLimit;
        emit TokenLimitsUpdated(token, _dailyLimit, _perTxLimit);
    }

    /// @notice Set default limits (used when token has no custom limits)
    function setDefaultLimits(uint256 _dailyLimit, uint256 _perTxLimit) external onlyOwner {
        defaultDailyLimit = _dailyLimit;
        defaultPerTxLimit = _perTxLimit;
        emit LimitsUpdated(_dailyLimit, _perTxLimit);
    }

    /// @notice Get effective daily limit for a token
    function effectiveDailyLimit(address token) public view returns (uint256) {
        uint256 custom = dailyLimit[token];
        return custom > 0 ? custom : defaultDailyLimit;
    }

    /// @notice Get effective per-tx limit for a token
    function effectivePerTxLimit(address token) public view returns (uint256) {
        uint256 custom = perTxLimit[token];
        return custom > 0 ? custom : defaultPerTxLimit;
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
        uint256 limit = effectiveDailyLimit(token);
        if (spent >= limit) return 0;
        return limit - spent;
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

        // If yield-only mode is on and this is stETH, can only spend harvested yield
        if (yieldOnly && token == stETH) {
            if (amount > spendableYield()) revert ExceedsBudget();
        } else {
            if (amount > IERC20(token).balanceOf(address(this))) revert ExceedsBudget();
        }

        if (amount > effectivePerTxLimit(token)) revert ExceedsPerTxLimit();
        uint256 today = block.timestamp / 1 days;
        if (dailySpent[token][today] + amount > effectiveDailyLimit(token)) revert ExceedsDailyLimit();
        if (whitelistEnabled && !whitelisted[to]) revert RecipientNotWhitelisted();
    }

    function _recordSpend(address token, address to, uint256 amount, string memory reason) internal {
        dailySpent[token][block.timestamp / 1 days] += amount;
        totalSpent[token] += amount;

        // Track yield spent for stETH in yield-only mode
        if (yieldOnly && token == stETH) {
            yieldSpent += amount;
        }

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
