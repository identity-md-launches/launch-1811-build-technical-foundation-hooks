// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HookSpec} from "../src/HookSpec.sol";
import {IHooksStore} from "../src/interfaces/IHooksStore.sol";
import {HookDeployment} from "../src/deployment/HookDeployment.sol";

/// @notice All inputs are explicit arguments. No key handling, env reads, tokens or pool creation.
contract DeployHook is Script {
    error InvalidBroadcaster();

    function prepare(address factory, HookSpec memory spec, uint256 startNonce, uint256 attempts)
        public
        view
        returns (IHooksStore.Plan memory)
    {
        return HookDeployment.prepare(factory, spec, startNonce, attempts);
    }

    function execute(address factory, HookSpec memory spec, IHooksStore.Plan memory plan)
        public
        returns (IHooksStore.Plan memory)
    {
        return HookDeployment.execute(factory, spec, plan);
    }

    function run(address broadcaster, address factory, HookSpec memory spec, uint256 startNonce, uint256 attempts)
        external
        returns (IHooksStore.Plan memory receipt)
    {
        if (broadcaster == address(0)) revert InvalidBroadcaster();
        IHooksStore.Plan memory plan = prepare(factory, spec, startNonce, attempts);
        vm.startBroadcast(broadcaster);
        receipt = execute(factory, spec, plan);
        vm.stopBroadcast();
    }
}
