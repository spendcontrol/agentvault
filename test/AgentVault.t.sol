// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract AgentVaultTest is Test {
    AgentVault vault;
    AgentVaultFactory factory;
    ERC20Mock usdc;

    address owner = address(0x1);
    address agent = address(0x2);
    address recipient = address(0x3);

    uint256 dailyLimit = 1000e6;    // 1000 USDC (6 decimals)
    uint256 perTxLimit = 500e6;     // 500 USDC

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC");

        factory = new AgentVaultFactory(address(0));

        vm.prank(owner);
        address vaultAddr = factory.createVault(agent, address(usdc), dailyLimit, perTxLimit);
        vault = AgentVault(vaultAddr);

        // Mint USDC to owner
        usdc.mint(owner, 100_000e6);
        vm.prank(owner);
        usdc.approve(address(vault), type(uint256).max);
    }

    // --- Deposit & Withdraw ---

    function test_deposit() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        assertEq(vault.totalDeposited(), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    function test_withdraw() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(owner);
        vault.withdraw(5_000e6);

        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(usdc.balanceOf(owner), 95_000e6);
    }

    function test_withdrawAll() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(owner);
        vault.withdraw(10_000e6);

        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // --- Agent Spend ---

    function test_agentSpend() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 100e6, "API call payment");

        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(vault.totalSpent(), 100e6);
        assertEq(vault.expenseCount(), 1);
    }

    function test_agentSpendNoReason() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 100e6);

        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_expenseReport() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 100e6, "GPT-4 API call");

        (uint256 ts, address to, uint256 amt, string memory reason) = vault.getExpense(0);
        assertEq(to, recipient);
        assertEq(amt, 100e6);
        assertEq(reason, "GPT-4 API call");
        assertGt(ts, 0);
    }

    // --- Limits ---

    function test_perTxLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsPerTxLimit.selector);
        vault.spend(recipient, 600e6); // limit is 500
    }

    function test_dailyLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 500e6);
        vm.prank(agent);
        vault.spend(recipient, 500e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsDailyLimit.selector);
        vault.spend(recipient, 100e6); // daily limit reached
    }

    function test_dailyLimitResetsNextDay() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 500e6);
        vm.prank(agent);
        vault.spend(recipient, 500e6);

        vm.warp(block.timestamp + 1 days);

        vm.prank(agent);
        vault.spend(recipient, 500e6); // works again
        assertEq(usdc.balanceOf(recipient), 1_500e6);
    }

    function test_budgetLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(100e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ExceedsBudget.selector);
        vault.spend(recipient, 200e6); // only 100 in vault
    }

    // --- Whitelist ---

    function test_whitelistEnforced() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        vm.prank(agent);
        vm.expectRevert(AgentVault.RecipientNotWhitelisted.selector);
        vault.spend(recipient, 100e6);

        vm.prank(owner);
        vault.setWhitelist(recipient, true);

        vm.prank(agent);
        vault.spend(recipient, 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    // --- Pause ---

    function test_pauseStopsAgent() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(agent);
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.spend(recipient, 100e6);
    }

    // --- Access Control ---

    function test_onlyOwnerDeposit() public {
        vm.prank(agent);
        vm.expectRevert(AgentVault.OnlyOwner.selector);
        vault.deposit(100e6);
    }

    function test_onlyAgentSpend() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(owner);
        vm.expectRevert(AgentVault.OnlyAgent.selector);
        vault.spend(recipient, 100e6);
    }

    // --- Factory ---

    function test_factoryTracksVaults() public {
        assertEq(factory.totalVaults(), 1);
        assertEq(factory.getVaultsByOwner(owner).length, 1);
        assertEq(factory.getVaultsByAgent(agent).length, 1);
    }

    // --- Stats ---

    function test_getStats() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vault.spend(recipient, 100e6, "test");

        (uint256 balance, uint256 deposited, uint256 spent, uint256 avail, uint256 dailyLeft) = vault.getStats();
        assertEq(balance, 9_900e6);
        assertEq(deposited, 10_000e6);
        assertEq(spent, 100e6);
        assertEq(avail, 9_900e6);
        assertEq(dailyLeft, 900e6);
    }

    // --- Zero address ---

    function test_zeroAddressReverts() public {
        vm.prank(owner);
        vault.deposit(10_000e6);

        vm.prank(agent);
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        vault.spend(address(0), 100e6);
    }
}
