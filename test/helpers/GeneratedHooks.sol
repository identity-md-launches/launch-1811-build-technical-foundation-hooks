// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {GatedHookDeployer} from "../../src/deployment/GatedHookDeployer.sol";

/// @dev Stand-in for a job-generated hook: arbitrary mask, manager in storage, standard readback.
contract GeneratedHook {
    address public poolManager;
    uint160 public flags;

    constructor(address manager, uint160 flags_) {
        poolManager = manager;
        flags = flags_;
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != flags_) revert("mask");
    }

    function getHookPermissions() public view returns (Hooks.Permissions memory p) {
        uint160 f = flags;
        p.beforeInitialize = f & Hooks.BEFORE_INITIALIZE_FLAG != 0;
        p.afterInitialize = f & Hooks.AFTER_INITIALIZE_FLAG != 0;
        p.beforeAddLiquidity = f & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0;
        p.afterAddLiquidity = f & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0;
        p.beforeRemoveLiquidity = f & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0;
        p.afterRemoveLiquidity = f & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0;
        p.beforeSwap = f & Hooks.BEFORE_SWAP_FLAG != 0;
        p.afterSwap = f & Hooks.AFTER_SWAP_FLAG != 0;
        p.beforeDonate = f & Hooks.BEFORE_DONATE_FLAG != 0;
        p.afterDonate = f & Hooks.AFTER_DONATE_FLAG != 0;
        p.beforeSwapReturnDelta = f & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0;
        p.afterSwapReturnDelta = f & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0;
        p.afterAddLiquidityReturnDelta = f & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0;
        p.afterRemoveLiquidityReturnDelta = f & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0;
    }
}

/// @dev Reports a different manager than its artifact names.
contract LyingManagerHook is GeneratedHook {
    constructor(address manager, uint160 flags_) GeneratedHook(address(uint160(manager) ^ 1), flags_) {}
}

/// @dev Reports more callbacks than its address enables.
contract LyingPermissionsHook is GeneratedHook {
    constructor(address manager, uint160 flags_) GeneratedHook(manager, flags_) {
        flags = flags_ | Hooks.BEFORE_DONATE_FLAG;
    }
}

/// @dev Tries to reenter the deployer from its constructor and swallows the result.
contract ReenteringHook is GeneratedHook {
    bool public reentered;

    constructor(address manager, uint160 flags_, address deployer) GeneratedHook(manager, flags_) {
        GatedHookDeployer.Artifact memory a;
        try GatedHookDeployer(deployer).deploy(a, "", "", "", bytes32(0), address(0)) {
            reentered = true;
        } catch {}
    }
}

/// @dev Returns empty runtime code.
contract EmptyRuntimeHook {
    constructor(address, uint160) {
        assembly {
            return(0, 0)
        }
    }
}

/// @dev Always reverts.
contract RevertingHook {
    constructor(address, uint160) {
        revert("nope");
    }
}

/// @dev Runtime code that depends on the deployment block: the reviewed runtime hash cannot match.
contract EnvironmentDependentHook is GeneratedHook {
    uint256 public immutable bornAt;

    constructor(address manager, uint160 flags_) GeneratedHook(manager, flags_) {
        bornAt = block.number;
    }
}
