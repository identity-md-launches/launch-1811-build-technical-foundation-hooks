// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookSpec} from "../HookSpec.sol";
import {HooksStoreFactory} from "../HooksStoreFactory.sol";
import {IHooksStore} from "../interfaces/IHooksStore.sol";
import {HookMiner} from "./HookMiner.sol";
import {DeploymentPolicy} from "./DeploymentPolicy.sol";

/// @notice One integration used by the script and available to Store adapters.
library HookDeployment {
    error UntrustedFactory();
    error SearchExhausted(uint256 nextNonce);
    error StalePlan();

    function checkFactory(address factory) internal view {
        DeploymentPolicy.requireTestChain();
        if (factory.codehash != keccak256(type(HooksStoreFactory).runtimeCode)) revert UntrustedFactory();
    }

    function prepare(address factory, HookSpec memory spec, uint256 startNonce, uint256 attempts)
        internal
        view
        returns (IHooksStore.Plan memory plan)
    {
        checkFactory(factory);
        HookMiner.Result memory result = IHooksStore(factory).mine(spec, startNonce, attempts);
        if (!result.found) revert SearchExhausted(result.nextNonce);
        plan = IHooksStore(factory).preview(spec, result.salt);
        if (plan.hook != result.hook) revert StalePlan();
    }

    function execute(address factory, HookSpec memory spec, IHooksStore.Plan memory plan)
        internal
        returns (IHooksStore.Plan memory receipt)
    {
        checkFactory(factory);
        IHooksStore.Plan memory current = IHooksStore(factory).preview(spec, plan.salt);
        if (keccak256(abi.encode(current)) != keccak256(abi.encode(plan))) revert StalePlan();
        IHooksStore.Plan memory deployed = IHooksStore(factory).deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        receipt = IHooksStore(factory).verify(spec, plan.salt, plan.hook);
        if (keccak256(abi.encode(receipt)) != keccak256(abi.encode(deployed))) revert StalePlan();
    }
}
