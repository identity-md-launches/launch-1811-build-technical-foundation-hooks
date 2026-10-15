// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookSpec, HookSpecLib} from "../../src/HookSpec.sol";
import {HooksStoreFactory} from "../../src/HooksStoreFactory.sol";
import {IHooksStore} from "../../src/interfaces/IHooksStore.sol";
import {HookMiner} from "../../src/deployment/HookMiner.sol";

abstract contract Fixture is Test {
    PoolManager internal manager;
    HooksStoreFactory internal factory;
    HookSpec internal spec;

    function setUp() public virtual {
        vm.chainId(31337);
        manager = new PoolManager(address(this));
        factory = new HooksStoreFactory();
        spec = HookSpec({
            schemaVersion: 1,
            templateId: HookSpecLib.TEMPLATE_ID,
            chainId: block.chainid,
            poolManager: address(manager),
            poolManagerCodeHash: address(manager).codehash,
            permissions: HookSpecLib.PERMISSIONS,
            maxSpecifiedAmount: 1_000_000
        });
    }

    function _plan(HookSpec memory input) internal view returns (IHooksStore.Plan memory) {
        uint256 start;
        for (uint256 page; page < 16; ++page) {
            HookMiner.Result memory result = factory.mine(input, start, 131072);
            if (result.found) return factory.preview(input, result.salt);
            start = result.nextNonce;
        }
        revert("test search exhausted");
    }

    function _deploy(HookSpec memory input) internal returns (IHooksStore.Plan memory plan) {
        plan = _plan(input);
        factory.deploy(input, plan.salt, plan.hook, plan.initCodeHash);
    }
}
