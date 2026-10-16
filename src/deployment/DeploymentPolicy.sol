// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Release policy of the Store tooling (factory, scripts, SDK), not of the hook template.
/// @dev This release permits only local development and named testnets. The restriction is a
/// property of this factory build: the BoundedSwapHook template and HookSpec v1 stay chain-agnostic
/// (the hook constructor only requires `spec.chainId == block.chainid`), so a later, separately
/// reviewed factory release can allow a mainnet by changing this list, without changing the hook
/// template, its bytecode or the spec. Anyone can deploy the public hook bytecode directly on any
/// chain; such a deployment is not a Store deployment and `verify` on this factory refuses it.
library DeploymentPolicy {
    error UnsupportedDeploymentChain(uint256 chainId);

    function isAllowed(uint256 id) internal pure returns (bool) {
        return id == 31337 || id == 11155111 || id == 84532 || id == 46630;
    }

    function requireTestChain() internal view {
        if (!isAllowed(block.chainid)) revert UnsupportedDeploymentChain(block.chainid);
    }
}
