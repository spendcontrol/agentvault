// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {YieldVaultFactory} from "../src/YieldVaultFactory.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract YieldVaultTest is Test {
    YieldVault vault;
    YieldVaultFactory factory;
    ERC20Mock wstETH;
    ERC20Mock stETH;

    address owner = address(0x1);
    address agent = address(0x2);
    address recipient = address(0x3);

    uint256 dailyLimit = 1 ether;
    uint256 perTxLimit = 0.5 ether;

    function setUp() public {
        wstETH = new ERC20Mock("Wrapped stETH", "wstETH");
        stETH = new ERC20Mock("Staked ETH", "stETH");

        // Deploy via factory
        factory = new YieldVaultFactory(address(wstETH), address(stETH));

        vm.prank(owner);
        address vaultAddr = factory.createVault(agent, dailyLimit, perTxLimit);
        vault = YieldVault(vaultAddr);

        // Mint wstETH to owner for deposits
        wstETH.mint(owner, 100 ether);

        // Approve vault
        vm.prank(owner);
        wstETH.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        assertEq(vault.principalWstETH(), 10 ether);
        assertEq(wstETH.balanceOf(address(vault)), 10 ether);
    }

    function test_noYieldInitially() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        assertEq(vault.availableYield(), 0);
    }

    function test_yieldAccrues() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        // Simulate yield: mint extra wstETH directly to vault
        wstETH.mint(address(vault), 0.5 ether);

        assertEq(vault.availableYield(), 0.5 ether);
    }

    function test_agentCanSpendYield() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        // Simulate yield
        wstETH.mint(address(vault), 0.5 ether);

        // Agent spends
        vm.prank(agent);
        vault.spend(recipient, 0.3 ether);

        assertEq(wstETH.balanceOf(recipient), 0.3 ether);
        assertEq(vault.availableYield(), 0.2 ether);
        assertEq(vault.totalYieldSpent(), 0.3 ether);
        // Principal untouched
        assertEq(vault.principalWstETH(), 10 ether);
    }

    function test_agentCannotSpendPrincipal() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        // No yield — agent tries to spend
        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsYield.selector);
        vault.spend(recipient, 1 ether);
    }

    function test_perTxLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 2 ether);

        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsPerTxLimit.selector);
        vault.spend(recipient, 0.6 ether); // perTxLimit = 0.5
    }

    function test_dailyLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 5 ether);

        // Spend up to daily limit
        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

        // This should fail — daily limit reached (1 ether)
        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsDailyLimit.selector);
        vault.spend(recipient, 0.1 ether);
    }

    function test_dailyLimitResetsNextDay() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 5 ether);

        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

        // Next day
        vm.warp(block.timestamp + 1 days);

        // Should work again
        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

        assertEq(wstETH.balanceOf(recipient), 1.5 ether);
    }

    function test_whitelistEnforced() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 1 ether);

        // Enable whitelist
        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        // Agent tries to send to non-whitelisted address
        vm.prank(agent);
        vm.expectRevert(YieldVault.RecipientNotWhitelisted.selector);
        vault.spend(recipient, 0.1 ether);

        // Owner whitelists recipient
        vm.prank(owner);
        vault.setWhitelist(recipient, true);

        // Now it works
        vm.prank(agent);
        vault.spend(recipient, 0.1 ether);
        assertEq(wstETH.balanceOf(recipient), 0.1 ether);
    }

    function test_pauseStopsAgent() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 1 ether);

        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(agent);
        vm.expectRevert(YieldVault.VaultPaused.selector);
        vault.spend(recipient, 0.1 ether);
    }

    function test_ownerCanWithdrawPrincipal() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        vm.prank(owner);
        vault.withdrawPrincipal(5 ether);

        assertEq(vault.principalWstETH(), 5 ether);
        assertEq(wstETH.balanceOf(owner), 95 ether); // started with 100, deposited 10, withdrew 5
    }

    function test_onlyOwnerCanDeposit() public {
        vm.prank(agent);
        vm.expectRevert(YieldVault.OnlyOwner.selector);
        vault.deposit(1 ether);
    }

    function test_onlyAgentCanSpend() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 1 ether);

        vm.prank(owner);
        vm.expectRevert(YieldVault.OnlyAgent.selector);
        vault.spend(recipient, 0.1 ether);
    }

    function test_factoryTracksVaults() public {
        assertEq(factory.totalVaults(), 1);
        assertEq(factory.getVaultsByOwner(owner).length, 1);
        assertEq(factory.getVaultsByAgent(agent).length, 1);

        // Create another vault
        vm.prank(owner);
        factory.createVault(address(0x99), 2 ether, 1 ether);

        assertEq(factory.totalVaults(), 2);
        assertEq(factory.getVaultsByOwner(owner).length, 2);
    }

    function test_getStats() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 0.5 ether);

        (
            uint256 principal,
            uint256 currentBalance,
            uint256 yield_,
            uint256 spent,
            uint256 remaining
        ) = vault.getStats();

        assertEq(principal, 10 ether);
        assertEq(currentBalance, 10.5 ether);
        assertEq(yield_, 0.5 ether);
        assertEq(spent, 0);
        assertEq(remaining, dailyLimit);
    }
}
