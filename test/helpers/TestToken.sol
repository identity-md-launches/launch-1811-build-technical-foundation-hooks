// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Local test fixture only. Deployment scripts never import this contract.
contract TestToken is ERC20 {
    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
