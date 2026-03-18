// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVaultFactory} from "../src/YieldVaultFactory.sol";

/// @notice Deploy YieldVaultFactory with wstETH/stETH addresses as constructor params
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast --private-key <KEY>
///      Set WSTETH_ADDRESS and STETH_ADDRESS env vars before running.
contract DeployScript is Script {
    function run() external {
        address wstETH = vm.envAddress("WSTETH_ADDRESS");
        address stETH = vm.envAddress("STETH_ADDRESS");

        vm.startBroadcast();

        YieldVaultFactory factory = new YieldVaultFactory(wstETH, stETH);

        console.log("YieldVaultFactory deployed at:", address(factory));
        console.log("  wstETH:", wstETH);
        console.log("  stETH:", stETH);

        vm.stopBroadcast();
    }
}
