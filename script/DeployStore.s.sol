// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HooksStoreFactory} from "../src/HooksStoreFactory.sol";
import {DeploymentPolicy} from "../src/deployment/DeploymentPolicy.sol";

/// @notice Bootstrap only the shared hook factory, on an allowed test chain.
contract DeployStore is Script {
    error InvalidBroadcaster();

    function run(address broadcaster) external returns (HooksStoreFactory factory) {
        DeploymentPolicy.requireTestChain();
        if (broadcaster == address(0)) revert InvalidBroadcaster();
        vm.startBroadcast(broadcaster);
        factory = new HooksStoreFactory();
        vm.stopBroadcast();
    }
}
