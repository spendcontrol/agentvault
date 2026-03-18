// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockStETH} from "../src/MockStETH.sol";
import {MockWstETH} from "../src/MockWstETH.sol";

contract AgentVaultTest is Test {
    AgentVault vault;
    AgentVaultFactory factory;
    ERC20Mock usdc;
    ERC20Mock weth;
    MockStETH stETH;
    MockWstETH wstETHMock;

    address owner = address(0x1);
    address agent = address(0x2);
    address recipient = address(0x3);

    uint256 dailyLimit = 1000e6;    // 1000 USDC
    uint256 perTxLimit = 500e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC");
        weth = new ERC20Mock("Wrapped ETH", "WETH");
        stETH = new MockStETH();
        wstETHMock = new MockWstETH();
        wstETHMock.setStETH(address(stETH));

        factory = new AgentVaultFactory(address(stETH), address(wstETHMock), address(0));

        vm.prank(owner);
        address vaultAddr = factory.createVault(agent, dailyLimit, perTxLimit);
        vault = AgentVault(vaultAddr);

        // Fund owner
        usdc.mint(owner, 100_000e6);
        weth.mint(owner, 100 ether);
        vm.deal(owner, 100 ether);

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // --- Multi-token deposit ---

    function test_depositUSDC() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(vault.balanceOf(address(usdc)), 10_000e6);
        assertTrue(vault.supportedTokens(address(usdc)));
    }

    function test_depositMultipleTokens() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 5_000e6);

        vm.prank(owner);
        vault.deposit(address(weth), 2 ether);

        assertEq(vault.balanceOf(address(usdc)), 5_000e6);
        assertEq(vault.balanceOf(address(weth)), 2 ether);

        address[] memory tokens = vault.getTokens();
        assertEq(tokens.length, 2);
    }

    // --- Stake ETH via Lido ---

    function test_stakeETH() public {
        vm.prank(owner);
        vault.stakeETH{value: 5 ether}(false);

        // stETH is deposited (not wstETH)
        assertEq(vault.balanceOf(address(stETH)), 5 ether);
        assertTrue(vault.supportedTokens(address(stETH)));
        assertEq(vault.stakedPrincipal(), 5 ether); // always recorded
    }

    function test_stakeETH_yieldOnly() public {
        vm.prank(owner);
        vault.stakeETH{value: 10 ether}(true);

        assertEq(vault.stakedPrincipal(), 10 ether);
        assertTrue(vault.yieldOnly());
        assertEq(vault.pendingYield(), 0); // no yield yet
        assertEq(vault.spendableYield(), 0);
    }

    function test_yieldOnly_harvestAndSpend() public {
        // Create vault with ETH-scale limits
        vm.prank(owner);
        address vAddr = factory.createVault(agent, 10 ether, 5 ether);
        AgentVault yVault = AgentVault(vAddr);

        // Stake with yield-only
        vm.prank(owner);
        yVault.stakeETH{value: 10 ether}(true);

        // Agent tries to spend — no harvested yield, should fail
        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsBudget.selector);
        yVault.spend(address(stETH), recipient, 0.1 ether);

        // Simulate stETH rebase: mint extra stETH to vault (this is what Lido does)
        stETH.mint(address(yVault), 0.5 ether);

        // Yield exists but not harvested yet
        assertEq(yVault.pendingYield(), 0.5 ether);
        assertEq(yVault.spendableYield(), 0);

        // Agent still can't spend (not harvested)
        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsBudget.selector);
        yVault.spend(address(stETH), recipient, 0.1 ether);

        // Harvest yield (anyone can call, once per day)
        vm.warp(block.timestamp + 1 days);
        yVault.harvestYield();

        // Now agent can spend harvested yield
        assertEq(yVault.spendableYield(), 0.5 ether);

        vm.prank(agent);
        yVault.spend(address(stETH), recipient, 0.3 ether, "Paid from staking yield");

        assertEq(stETH.balanceOf(recipient), 0.3 ether);
        assertEq(yVault.spendableYield(), 0.2 ether);
        // Principal untouched
        assertEq(yVault.stakedPrincipal(), 10 ether);
    }

    function test_harvestYield_oncePerDay() public {
        vm.prank(owner);
        vault.stakeETH{value: 10 ether}(true);

        stETH.mint(address(vault), 0.1 ether);
        vm.warp(block.timestamp + 1 days);
        vault.harvestYield();

        // Try to harvest again same day — should fail
        stETH.mint(address(vault), 0.1 ether);
        vm.expectRevert("Already harvested today");
        vault.harvestYield();

        // Next day — should work
        vm.warp(block.timestamp + 1 days);
        vault.harvestYield();
        assertEq(vault.spendableYield(), 0.2 ether);
    }

    function test_yieldOnly_ownerCanWithdrawPrincipal() public {
        vm.prank(owner);
        vault.stakeETH{value: 10 ether}(true);

        vm.prank(owner);
        vault.withdrawPrincipal(5 ether);

        assertEq(vault.stakedPrincipal(), 5 ether);
        assertEq(stETH.balanceOf(owner), 5 ether);
    }

    function test_yieldOnly_normalTokensUnaffected() public {
        // Stake ETH in yield-only mode
        vm.prank(owner);
        vault.stakeETH{value: 1 ether}(true);

        // Also deposit USDC normally
        vm.prank(owner);
        vault.deposit(address(usdc), 5_000e6);

        // Agent can freely spend USDC (not affected by yieldOnly)
        vm.prank(agent);
        vault.spend(address(usdc), recipient, 100e6, "USDC payment");

        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    // --- Agent spend ---

    function test_agentSpendUSDC() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(agent);
        vault.spend(address(usdc), recipient, 100e6, "API payment");

        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(vault.totalSpent(address(usdc)), 100e6);
        assertEq(vault.expenseCount(), 1);
    }

    function test_agentSpendWETH() public {
        // Create a vault with ETH-scale limits
        vm.prank(owner);
        address vAddr = factory.createVault(agent, 10 ether, 5 ether);
        AgentVault ethVault = AgentVault(vAddr);

        vm.prank(owner);
        weth.approve(address(ethVault), type(uint256).max);
        vm.prank(owner);
        ethVault.deposit(address(weth), 10 ether);

        vm.prank(agent);
        ethVault.spend(address(weth), recipient, 0.5 ether, "Gas refill");

        assertEq(weth.balanceOf(recipient), 0.5 ether);
    }

    function test_agentCannotSpendUnsupportedToken() public {
        ERC20Mock random = new ERC20Mock("Random", "RND");
        random.mint(address(vault), 1000e18); // tokens in vault but not deposited via deposit()

        vm.prank(agent);
        vm.expectRevert(AgentVault.TokenNotSupported.selector);
        vault.spend(address(random), recipient, 100e18);
    }

    function test_expenseReportWithToken() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(agent);
        vault.spend(address(usdc), recipient, 50e6, "Claude API call");

        (uint256 ts, address token, address to, uint256 amt, string memory reason) = vault.getExpense(0);
        assertEq(token, address(usdc));
        assertEq(to, recipient);
        assertEq(amt, 50e6);
        assertEq(reason, "Claude API call");
    }

    // --- Limits ---

    function test_perTxLimit() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsPerTxLimit.selector);
        vault.spend(address(usdc), recipient, 600e6);
    }

    function test_dailyLimit() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(agent);
        vault.spend(address(usdc), recipient, 500e6);
        vm.prank(agent);
        vault.spend(address(usdc), recipient, 500e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsDailyLimit.selector);
        vault.spend(address(usdc), recipient, 100e6);
    }

    function test_dailyLimitResetsNextDay() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(agent);
        vault.spend(address(usdc), recipient, 500e6);
        vm.prank(agent);
        vault.spend(address(usdc), recipient, 500e6);

        vm.warp(block.timestamp + 1 days);

        vm.prank(agent);
        vault.spend(address(usdc), recipient, 500e6);
        assertEq(usdc.balanceOf(recipient), 1_500e6);
    }

    // --- Withdraw ---

    function test_withdraw() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(owner);
        vault.withdraw(address(usdc), 5_000e6);

        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
    }

    // --- Pause ---

    function test_pause() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(agent);
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.spend(address(usdc), recipient, 100e6);
    }

    // --- Access control ---

    function test_onlyOwnerDeposit() public {
        vm.prank(agent);
        vm.expectRevert(AgentVault.OnlyOwner.selector);
        vault.deposit(address(usdc), 100e6);
    }

    function test_onlyAgentSpend() public {
        vm.prank(owner);
        vault.deposit(address(usdc), 10_000e6);

        vm.prank(owner);
        vm.expectRevert(AgentVault.OnlyAgent.selector);
        vault.spend(address(usdc), recipient, 100e6);
    }

    // --- Factory ---

    function test_factory() public {
        assertEq(factory.totalVaults(), 1);
        assertEq(factory.getVaultsByOwner(owner).length, 1);
        assertEq(factory.getVaultsByAgent(agent).length, 1);
    }

    // --- Full flow ---

    function test_fullFlow_depositUSDC_agentSpends_ownerWithdraws() public {
        // Owner deposits
        vm.prank(owner);
        vault.deposit(address(usdc), 5_000e6);

        // Agent spends
        vm.prank(agent);
        vault.spend(address(usdc), recipient, 200e6, "Bought data feed access");

        // Verify
        assertEq(usdc.balanceOf(recipient), 200e6);
        assertEq(vault.balanceOf(address(usdc)), 4_800e6);

        // Owner withdraws remainder
        vm.prank(owner);
        vault.withdraw(address(usdc), 4_800e6);

        assertEq(vault.balanceOf(address(usdc)), 0);
    }

    function test_fullFlow_stakeETH_agentSpendsStETH() public {
        // Create vault with ETH-scale limits
        vm.prank(owner);
        address vAddr = factory.createVault(agent, 10 ether, 5 ether);
        AgentVault ethVault = AgentVault(vAddr);

        // Owner stakes ETH → stETH (not yield-only, agent can spend all)
        vm.prank(owner);
        ethVault.stakeETH{value: 10 ether}(false);

        // Agent spends stETH
        vm.prank(agent);
        ethVault.spend(address(stETH), recipient, 0.5 ether, "Paid for compute");

        assertEq(stETH.balanceOf(recipient), 0.5 ether);
        assertEq(ethVault.balanceOf(address(stETH)), 9.5 ether);
    }
}
