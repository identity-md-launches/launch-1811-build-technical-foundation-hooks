// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice The ABI counterpart of schemas/hook-spec.v1.schema.json. All fields are committed by hash().
struct HookSpec {
    uint32 schemaVersion;
    bytes32 templateId;
    uint256 chainId;
    address poolManager;
    bytes32 poolManagerCodeHash;
    uint160 permissions;
    uint128 maxSpecifiedAmount;
}

library HookSpecLib {
    uint32 internal constant VERSION = 1;
    bytes32 internal constant TEMPLATE_ID = keccak256("hooks-store/bounded-swap/v1");
    uint160 internal constant PERMISSIONS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG;
    bytes32 internal constant TYPEHASH = keccak256(
        "HookSpec(uint32 schemaVersion,bytes32 templateId,uint256 chainId,address poolManager,bytes32 poolManagerCodeHash,uint160 permissions,uint128 maxSpecifiedAmount)"
    );

    error UnsupportedVersion(uint32 version);
    error UnsupportedTemplate(bytes32 templateId);
    error InvalidChainId();
    error InvalidManager();
    error InvalidManagerCodeHash();
    error InvalidPermissions(uint160 permissions);
    error InvalidLimit();
    error WrongChain(uint256 requested, uint256 actual);

    function validate(HookSpec memory spec) internal pure {
        if (spec.schemaVersion != VERSION) revert UnsupportedVersion(spec.schemaVersion);
        if (spec.templateId != TEMPLATE_ID) revert UnsupportedTemplate(spec.templateId);
        if (spec.chainId == 0) revert InvalidChainId();
        if (spec.poolManager == address(0)) revert InvalidManager();
        if (spec.poolManagerCodeHash == bytes32(0) || spec.poolManagerCodeHash == keccak256("")) {
            revert InvalidManagerCodeHash();
        }
        if (spec.permissions != PERMISSIONS) revert InvalidPermissions(spec.permissions);
        if (spec.maxSpecifiedAmount == 0) revert InvalidLimit();
    }

    function hash(HookSpec memory spec) internal pure returns (bytes32) {
        return keccak256(abi.encode(TYPEHASH, spec));
    }

    function validateChain(HookSpec memory spec) internal view {
        validate(spec);
        if (spec.chainId != block.chainid) revert WrongChain(spec.chainId, block.chainid);
    }

    function hookPermissions() internal pure returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }
}
