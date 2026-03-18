// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";

contract DeployScript is Script {
    function run() external {
        address stETH = vm.envOr("STETH_ADDRESS", address(0));
        address wstETH = vm.envOr("WSTETH_ADDRESS", address(0));
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        vm.startBroadcast();
        new AgentVaultFactory(stETH, wstETH, swapRouter);
        vm.stopBroadcast();
    }
}
