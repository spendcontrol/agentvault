// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockWstETH} from "../src/MockWstETH.sol";
import {MockStETH} from "../src/MockStETH.sol";
import {YieldVaultFactory} from "../src/YieldVaultFactory.sol";

/// @notice Deploy mock wstETH/stETH + YieldVaultFactory on testnet
/// @dev Usage: forge script script/DeployMocks.s.sol --rpc-url <RPC> --broadcast --private-key <KEY>
contract DeployMocksScript is Script {
    function run() external {
        vm.startBroadcast();

        MockWstETH wstETH = new MockWstETH();
        console.log("MockWstETH deployed at:", address(wstETH));

        MockStETH stETH = new MockStETH();
        console.log("MockStETH deployed at:", address(stETH));

        YieldVaultFactory factory = new YieldVaultFactory(address(wstETH), address(stETH));
        console.log("YieldVaultFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
