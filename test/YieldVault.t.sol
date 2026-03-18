// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {YieldVaultFactory} from "../src/YieldVaultFactory.sol";
import {MockWstETH} from "../src/MockWstETH.sol";
import {MockStETH} from "../src/MockStETH.sol";

contract YieldVaultTest is Test {
    YieldVault vault;
    YieldVaultFactory factory;
    MockWstETH wstETH;
    MockStETH stETH;

    address owner = address(0x1);
    address agent = address(0x2);
    address recipient = address(0x3);

    uint256 dailyLimit = 1 ether;
    uint256 perTxLimit = 0.5 ether;

    function setUp() public {
        wstETH = new MockWstETH();
        stETH = new MockStETH();
        wstETH.setStETH(address(stETH));

        factory = new YieldVaultFactory(address(wstETH), address(stETH));

        vm.prank(owner);
        address vaultAddr = factory.createVault(agent, dailyLimit, perTxLimit);
        vault = YieldVault(vaultAddr);

        // Mint wstETH to owner for direct deposit tests
        wstETH.mint(owner, 100 ether);
        vm.prank(owner);
        wstETH.approve(address(vault), type(uint256).max);

        // Give owner ETH for depositETH tests
        vm.deal(owner, 100 ether);
    }

    // --- depositETH tests ---

    function test_depositETH() public {
        vm.prank(owner);
        vault.depositETH{value: 10 ether}();

        assertEq(vault.principalWstETH(), 10 ether);
        assertEq(vault.availableYield(), 0);
    }

    function test_depositETH_multipleDeposits() public {
        vm.prank(owner);
        vault.depositETH{value: 5 ether}();

        vm.prank(owner);
        vault.depositETH{value: 3 ether}();

        assertEq(vault.principalWstETH(), 8 ether);
    }

    function test_depositETH_thenYieldAccrues() public {
        vm.prank(owner);
        vault.depositETH{value: 10 ether}();

        // Simulate yield by minting extra wstETH to vault
        wstETH.mint(address(vault), 0.5 ether);

        assertEq(vault.principalWstETH(), 10 ether);
        assertEq(vault.availableYield(), 0.5 ether);
    }

    function test_depositETH_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(YieldVault.ZeroAmount.selector);
        vault.depositETH{value: 0}();
    }

    function test_depositETH_onlyOwner() public {
        vm.deal(agent, 10 ether);
        vm.prank(agent);
        vm.expectRevert(YieldVault.OnlyOwner.selector);
        vault.depositETH{value: 1 ether}();
    }

    // --- direct wstETH deposit tests ---

    function test_deposit() public {
        vm.prank(owner);
        vault.deposit(10 ether);

        assertEq(vault.principalWstETH(), 10 ether);
    }

    function test_noYieldInitially() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        assertEq(vault.availableYield(), 0);
    }

    function test_yieldAccrues() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 0.5 ether);
        assertEq(vault.availableYield(), 0.5 ether);
    }

    // --- Agent spend tests ---

    function test_agentCanSpendYield() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 0.5 ether);

        vm.prank(agent);
        vault.spend(recipient, 0.3 ether);

        assertEq(wstETH.balanceOf(recipient), 0.3 ether);
        assertEq(vault.availableYield(), 0.2 ether);
        assertEq(vault.totalYieldSpent(), 0.3 ether);
        assertEq(vault.principalWstETH(), 10 ether);
    }

    function test_agentCannotSpendPrincipal() public {
        vm.prank(owner);
        vault.deposit(10 ether);

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
        vault.spend(recipient, 0.6 ether);
    }

    function test_dailyLimitEnforced() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 5 ether);

        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);
        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);

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

        vm.warp(block.timestamp + 1 days);

        vm.prank(agent);
        vault.spend(recipient, 0.5 ether);
        assertEq(wstETH.balanceOf(recipient), 1.5 ether);
    }

    function test_whitelistEnforced() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 1 ether);

        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        vm.prank(agent);
        vm.expectRevert(YieldVault.RecipientNotWhitelisted.selector);
        vault.spend(recipient, 0.1 ether);

        vm.prank(owner);
        vault.setWhitelist(recipient, true);

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
        assertEq(wstETH.balanceOf(owner), 95 ether);
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

        vm.prank(owner);
        factory.createVault(address(0x99), 2 ether, 1 ether);

        assertEq(factory.totalVaults(), 2);
        assertEq(factory.getVaultsByOwner(owner).length, 2);
    }

    function test_getStats() public {
        vm.prank(owner);
        vault.deposit(10 ether);
        wstETH.mint(address(vault), 0.5 ether);

        (uint256 principal, uint256 currentBalance, uint256 yield_, uint256 spent, uint256 remaining) = vault.getStats();

        assertEq(principal, 10 ether);
        assertEq(currentBalance, 10.5 ether);
        assertEq(yield_, 0.5 ether);
        assertEq(spent, 0);
        assertEq(remaining, dailyLimit);
    }

    // --- Full flow: depositETH → yield → agent spends ---

    function test_fullFlow_depositETH_yieldAccrues_agentSpends() public {
        // 1. Owner deposits ETH (auto-stakes via Lido mock)
        vm.prank(owner);
        vault.depositETH{value: 10 ether}();
        assertEq(vault.principalWstETH(), 10 ether);

        // 2. Time passes, yield accrues (simulated by minting)
        wstETH.mint(address(vault), 0.35 ether);
        assertEq(vault.availableYield(), 0.35 ether);

        // 3. Agent spends yield
        vm.prank(agent);
        vault.spend(recipient, 0.2 ether);

        // 4. Verify
        assertEq(vault.principalWstETH(), 10 ether);      // principal untouched
        assertEq(vault.availableYield(), 0.15 ether);      // remaining yield
        assertEq(vault.totalYieldSpent(), 0.2 ether);      // tracked
        assertEq(wstETH.balanceOf(recipient), 0.2 ether);  // recipient got paid
    }
}
