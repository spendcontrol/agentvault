// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault, ISwapRouter} from "../src/YieldVault.sol";
import {YieldVaultFactory} from "../src/YieldVaultFactory.sol";
import {MockWstETH} from "../src/MockWstETH.sol";
import {MockStETH} from "../src/MockStETH.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract YieldVaultSwapTest is Test {
    YieldVault vault;
    YieldVaultFactory factory;
    MockWstETH wstETH;
    MockStETH stETH;
    ERC20Mock usdc;
    MockSwapRouter router;

    address owner = address(0x1);
    address agent = address(0x2);
    address recipient = address(0x3);

    uint256 dailyLimit = 1 ether;
    uint256 perTxLimit = 0.5 ether;
    uint24 poolFee = 3000; // 0.3%

    // 1 wstETH = 2000 USDC (mock rate)
    uint256 mockRate = 2000e18;

    function setUp() public {
        wstETH = new MockWstETH();
        stETH = new MockStETH();
        wstETH.setStETH(address(stETH));
        usdc = new ERC20Mock("USD Coin", "USDC");

        router = new MockSwapRouter(mockRate, address(usdc));

        // Pre-fund the router with USDC so it can pay out swaps
        usdc.mint(address(router), 1_000_000 ether);

        factory = new YieldVaultFactory(address(wstETH), address(stETH), address(router));

        vm.prank(owner);
        address vaultAddr = factory.createVault(agent, dailyLimit, perTxLimit);
        vault = YieldVault(vaultAddr);

        // Deposit principal and simulate yield
        wstETH.mint(owner, 100 ether);
        vm.prank(owner);
        wstETH.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        vault.deposit(10 ether);

        // Simulate yield accrual
        wstETH.mint(address(vault), 2 ether);
    }

    // --- Happy path ---

    function test_spendAndSwap_basic() public {
        uint256 amountIn = 0.3 ether;
        uint256 expectedOut = amountIn * mockRate / 1e18;

        vm.prank(agent);
        uint256 amountOut = vault.spendAndSwap(address(usdc), poolFee, amountIn, 0, recipient);

        assertEq(amountOut, expectedOut);
        assertEq(usdc.balanceOf(recipient), expectedOut);
        assertEq(vault.totalYieldSpent(), amountIn);
        assertEq(vault.principalWstETH(), 10 ether); // principal untouched
    }

    function test_spendAndSwap_emitsEvent() public {
        uint256 amountIn = 0.2 ether;
        uint256 expectedOut = amountIn * mockRate / 1e18;

        vm.expectEmit(true, true, true, true);
        emit YieldVault.YieldSwapped(agent, address(usdc), amountIn, expectedOut, recipient);

        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, amountIn, 0, recipient);
    }

    function test_spendAndSwap_tracksDaily() public {
        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, 0.4 ether, 0, recipient);

        uint256 today = block.timestamp / 1 days;
        assertEq(vault.dailySpent(today), 0.4 ether);
        assertEq(vault.remainingDailyBudget(), 0.6 ether);
    }

    function test_spendAndSwap_respectsAmountOutMinimum() public {
        uint256 amountIn = 0.1 ether;
        uint256 expectedOut = amountIn * mockRate / 1e18;
        // Ask for exactly the expected output -- should succeed
        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, amountIn, expectedOut, recipient);
        assertEq(usdc.balanceOf(recipient), expectedOut);
    }

    // --- Guard checks (same as spend) ---

    function test_spendAndSwap_revertsZeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(YieldVault.ZeroAmount.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0, 0, recipient);
    }

    function test_spendAndSwap_revertsExceedsYield() public {
        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsYield.selector);
        vault.spendAndSwap(address(usdc), poolFee, 3 ether, 0, recipient);
    }

    function test_spendAndSwap_revertsExceedsPerTxLimit() public {
        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsPerTxLimit.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0.6 ether, 0, recipient);
    }

    function test_spendAndSwap_revertsExceedsDailyLimit() public {
        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, 0.5 ether, 0, recipient);
        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, 0.5 ether, 0, recipient);

        vm.prank(agent);
        vm.expectRevert(YieldVault.ExceedsDailyLimit.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0.1 ether, 0, recipient);
    }

    function test_spendAndSwap_revertsWhenPaused() public {
        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(agent);
        vm.expectRevert(YieldVault.VaultPaused.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0.1 ether, 0, recipient);
    }

    function test_spendAndSwap_revertsNonWhitelisted() public {
        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        vm.prank(agent);
        vm.expectRevert(YieldVault.RecipientNotWhitelisted.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0.1 ether, 0, recipient);
    }

    function test_spendAndSwap_succeedsWhenWhitelisted() public {
        vm.prank(owner);
        vault.setWhitelistEnabled(true);
        vm.prank(owner);
        vault.setWhitelist(recipient, true);

        vm.prank(agent);
        vault.spendAndSwap(address(usdc), poolFee, 0.1 ether, 0, recipient);
        assertGt(usdc.balanceOf(recipient), 0);
    }

    function test_spendAndSwap_onlyAgent() public {
        vm.prank(owner);
        vm.expectRevert(YieldVault.OnlyAgent.selector);
        vault.spendAndSwap(address(usdc), poolFee, 0.1 ether, 0, recipient);
    }

    function test_spendAndSwap_revertsOnSlippage() public {
        uint256 amountIn = 0.1 ether;
        uint256 tooHigh = amountIn * mockRate / 1e18 + 1;

        vm.prank(agent);
        vm.expectRevert("Too little received");
        vault.spendAndSwap(address(usdc), poolFee, amountIn, tooHigh, recipient);
    }

    // --- Factory passes swapRouter ---

    function test_factoryPassesSwapRouter() public {
        assertEq(vault.swapRouter(), address(router));
    }
}
