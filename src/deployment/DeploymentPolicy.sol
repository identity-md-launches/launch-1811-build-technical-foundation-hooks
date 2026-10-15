// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice This release only permits local development and named testnets. No mainnet deployment path.
library DeploymentPolicy {
    error UnsupportedDeploymentChain(uint256 chainId);

    function requireTestChain() internal view {
        uint256 id = block.chainid;
        if (id != 31337 && id != 11155111 && id != 84532 && id != 46630) {
            revert UnsupportedDeploymentChain(id);
        }
    }
}
