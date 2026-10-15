// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DisabledCallbacks} from "./DisabledCallbacks.sol";
import {HookSpec, HookSpecLib} from "./HookSpec.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Reusable, permissionless, fixed-configuration hook for NEW static-fee v4 pools.
/// @dev Caps the requested specified currency in raw units, not notional value or cumulative volume.
contract BoundedSwapHook is DisabledCallbacks {
    using PoolIdLibrary for PoolKey;

    // Write-once storage (no setters) deliberately keeps runtime bytecode independent of constructor arguments.
    IPoolManager public poolManager;
    uint128 public maxSpecifiedAmount;
    bytes32 public specHash;
    bytes32 public poolManagerCodeHash;
    uint256 public deploymentChainId;

    mapping(PoolId => bool) public initialized;
    mapping(PoolId => uint256) public swapCount;

    error OnlyPoolManager();
    error WrongHook();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();
    error DynamicFeeUnsupported();
    error AmountOutsideLimit(int256 amountSpecified, uint128 limit);

    event PoolRegistered(PoolId indexed poolId);
    event SwapObserved(PoolId indexed poolId, address indexed sender, uint256 count);

    constructor(HookSpec memory spec) {
        HookSpecLib.validateChain(spec);
        Hooks.validateHookPermissions(IHooks(address(this)), HookSpecLib.hookPermissions());
        poolManager = IPoolManager(spec.poolManager);
        maxSpecifiedAmount = spec.maxSpecifiedAmount;
        specHash = HookSpecLib.hash(spec);
        poolManagerCodeHash = spec.poolManagerCodeHash;
        deploymentChainId = spec.chainId;
    }

    modifier onlyManager(PoolKey calldata key) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (address(key.hooks) != address(this)) revert WrongHook();
        _;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return HookSpecLib.hookPermissions();
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyManager(key) returns (bytes4) {
        if (key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeUnsupported();
        PoolId id = key.toId();
        if (initialized[id]) revert PoolAlreadyInitialized();
        initialized[id] = true;
        emit PoolRegistered(id);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyManager(key)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!initialized[key.toId()]) revert PoolNotInitialized();
        int256 limit = int256(uint256(maxSpecifiedAmount));
        // Compare signed bounds directly: negating int256.min would overflow.
        if (params.amountSpecified == 0 || params.amountSpecified < -limit || params.amountSpecified > limit) {
            revert AmountOutsideLimit(params.amountSpecified, maxSpecifiedAmount);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyManager(key) returns (bytes4, int128) {
        PoolId id = key.toId();
        if (!initialized[id]) revert PoolNotInitialized();
        uint256 count = ++swapCount[id];
        emit SwapObserved(id, sender, count);
        return (IHooks.afterSwap.selector, 0);
    }
}
