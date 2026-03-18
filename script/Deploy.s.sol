// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";

contract DeployScript is Script {
    function run() external {
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        vm.startBroadcast();
        new AgentVaultFactory(swapRouter);
        vm.stopBroadcast();
    }
}
