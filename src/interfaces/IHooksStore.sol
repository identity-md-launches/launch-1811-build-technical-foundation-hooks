// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookSpec} from "../HookSpec.sol";
import {HookMiner} from "../deployment/HookMiner.sol";

/// @notice Shared ABI for both creator frontends. Hashes are commitments, not signatures or an audit.
interface IHooksStore {
    struct Plan {
        uint256 chainId;
        address factory;
        address hook;
        bytes32 salt;
        bytes32 specHash;
        bytes32 initCodeHash;
        bytes32 runtimeCodeHash;
        uint160 permissions;
    }

    event HookDeployed(
        address indexed hook, bytes32 indexed specHash, bytes32 salt, bytes32 initCodeHash, bytes32 runtimeCodeHash
    );

    function preview(HookSpec calldata spec, bytes32 salt) external view returns (Plan memory);
    function mine(HookSpec calldata spec, uint256 startNonce, uint256 attempts)
        external
        view
        returns (HookMiner.Result memory);
    function deploy(HookSpec calldata spec, bytes32 salt, address expectedHook, bytes32 expectedInitCodeHash)
        external
        returns (Plan memory);
    function verify(HookSpec calldata spec, bytes32 salt, address hook) external view returns (Plan memory);
    function initCode(HookSpec calldata spec) external view returns (bytes memory);
    function runtimeCodeHash() external pure returns (bytes32);
    function deployedSpecHash(address hook) external view returns (bytes32);
}
