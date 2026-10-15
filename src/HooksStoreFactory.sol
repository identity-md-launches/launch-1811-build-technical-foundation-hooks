// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BoundedSwapHook} from "./BoundedSwapHook.sol";
import {HookSpec, HookSpecLib} from "./HookSpec.sol";
import {IHooksStore} from "./interfaces/IHooksStore.sol";
import {HookMiner} from "./deployment/HookMiner.sol";
import {DeploymentPolicy} from "./deployment/DeploymentPolicy.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Deploys only the fixed BoundedSwapHook template; never creates tokens, managers or pools.
contract HooksStoreFactory is IHooksStore {
    mapping(address => bytes32) public deployedSpecHash;

    error ManagerHasNoCode();
    error ManagerCodeHashMismatch(bytes32 expected, bytes32 actual);
    error PredictionMismatch();
    error InitCodeHashMismatch();
    error PermissionBitsMismatch(address hook);
    error AddressOccupied(address hook);
    error UnknownDeployment();
    error RuntimeCodeMismatch();
    error ConstructorSettingsMismatch();

    constructor() {
        DeploymentPolicy.requireTestChain();
    }

    function initCode(HookSpec calldata spec) external view returns (bytes memory) {
        _validateTarget(spec);
        return _initCode(spec);
    }

    function runtimeCodeHash() public pure returns (bytes32) {
        return keccak256(type(BoundedSwapHook).runtimeCode);
    }

    function preview(HookSpec calldata spec, bytes32 salt) public view returns (Plan memory plan) {
        _validateTarget(spec);
        bytes32 initHash = keccak256(_initCode(spec));
        plan = Plan(
            block.chainid,
            address(this),
            HookMiner.predict(address(this), salt, initHash),
            salt,
            HookSpecLib.hash(spec),
            initHash,
            runtimeCodeHash(),
            HookSpecLib.PERMISSIONS
        );
    }

    function mine(HookSpec calldata spec, uint256 startNonce, uint256 attempts)
        external
        view
        returns (HookMiner.Result memory)
    {
        _validateTarget(spec);
        return HookMiner.mine(address(this), keccak256(_initCode(spec)), HookSpecLib.PERMISSIONS, startNonce, attempts);
    }

    function deploy(HookSpec calldata spec, bytes32 salt, address expectedHook, bytes32 expectedInitCodeHash)
        external
        returns (Plan memory plan)
    {
        DeploymentPolicy.requireTestChain();
        plan = preview(spec, salt);
        if (plan.hook != expectedHook) revert PredictionMismatch();
        if (plan.initCodeHash != expectedInitCodeHash) revert InitCodeHashMismatch();
        _checkBits(plan.hook);
        if (plan.hook.code.length != 0) revert AddressOccupied(plan.hook);

        BoundedSwapHook hook = new BoundedSwapHook{salt: salt}(spec);
        if (address(hook) != plan.hook) revert PredictionMismatch();
        deployedSpecHash[address(hook)] = plan.specHash;
        _verify(plan, spec);
        emit HookDeployed(plan.hook, plan.specHash, salt, plan.initCodeHash, plan.runtimeCodeHash);
    }

    function verify(HookSpec calldata spec, bytes32 salt, address hook) external view returns (Plan memory plan) {
        plan = preview(spec, salt);
        if (hook != plan.hook) revert PredictionMismatch();
        _verify(plan, spec);
    }

    function _verify(Plan memory plan, HookSpec calldata spec) internal view {
        _checkBits(plan.hook);
        if (deployedSpecHash[plan.hook] != plan.specHash) revert UnknownDeployment();
        if (plan.hook.codehash != plan.runtimeCodeHash) revert RuntimeCodeMismatch();
        BoundedSwapHook hook = BoundedSwapHook(plan.hook);
        if (
            address(hook.poolManager()) != spec.poolManager || hook.maxSpecifiedAmount() != spec.maxSpecifiedAmount
                || hook.specHash() != plan.specHash || hook.poolManagerCodeHash() != spec.poolManagerCodeHash
                || hook.deploymentChainId() != spec.chainId
                || keccak256(abi.encode(hook.getHookPermissions()))
                    != keccak256(abi.encode(HookSpecLib.hookPermissions()))
        ) revert ConstructorSettingsMismatch();
    }

    function _validateTarget(HookSpec calldata spec) internal view {
        HookSpecLib.validateChain(spec);
        if (spec.poolManager.code.length == 0) revert ManagerHasNoCode();
        bytes32 actual = spec.poolManager.codehash;
        if (actual != spec.poolManagerCodeHash) revert ManagerCodeHashMismatch(spec.poolManagerCodeHash, actual);
    }

    function _checkBits(address hook) internal pure {
        if (uint160(hook) & Hooks.ALL_HOOK_MASK != HookSpecLib.PERMISSIONS) revert PermissionBitsMismatch(hook);
    }

    function _initCode(HookSpec calldata spec) internal pure returns (bytes memory) {
        return bytes.concat(type(BoundedSwapHook).creationCode, abi.encode(spec));
    }
}
