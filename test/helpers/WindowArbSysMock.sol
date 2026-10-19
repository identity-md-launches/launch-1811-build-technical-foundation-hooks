// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Native L2 height deliberately independent of the EVM/L1 height in tests.
contract WindowArbSysMock {
    uint256 public arbBlockNumber;

    function setHead(uint256 value) external {
        arbBlockNumber = value;
    }
}
