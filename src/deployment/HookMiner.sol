// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

library HookMiner {
    uint256 internal constant MAX_ATTEMPTS = 131072;

    struct Result {
        bool found;
        bytes32 salt;
        address hook;
        uint256 nextNonce;
    }

    error InvalidSearchRange();
    error InvalidFlags();

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        address predicted;
        // Reuse temporary memory so a long search does not incur quadratic memory expansion.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(248, 0xff))
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            predicted := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        return predicted;
    }

    /// @dev Paginated and bounded. Run via eth_call or a local script, never a paid mining transaction.
    function mine(address deployer, bytes32 initCodeHash, uint160 flags, uint256 start, uint256 attempts)
        internal
        view
        returns (Result memory result)
    {
        if (flags & ~Hooks.ALL_HOOK_MASK != 0) revert InvalidFlags();
        if (attempts == 0 || attempts > MAX_ATTEMPTS || start > type(uint256).max - attempts) {
            revert InvalidSearchRange();
        }
        uint256 end = start + attempts;
        for (uint256 nonce = start; nonce < end; ++nonce) {
            address candidate = predict(deployer, bytes32(nonce), initCodeHash);
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == flags && candidate.code.length == 0) {
                return Result(true, bytes32(nonce), candidate, nonce + 1);
            }
        }
        return Result(false, bytes32(0), address(0), end);
    }
}
