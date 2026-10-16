// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStoreToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Internal-only token helpers: accept true/no return; reject missing code and malformed results.
library ExactStoreToken {
    error TokenCallFailed();
    error InexactTransfer();

    function balance(address token, address account) internal view returns (uint256) {
        if (token.code.length == 0) revert TokenCallFailed();
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IStoreToken.balanceOf, (account)));
        if (!ok || data.length != 32) revert TokenCallFailed();
        return abi.decode(data, (uint256));
    }

    function call(address token, bytes memory input) internal {
        if (token.code.length == 0) revert TokenCallFailed();
        (bool ok, bytes memory data) = token.call(input);
        if (!ok || (data.length != 0 && (data.length != 32 || abi.decode(data, (uint256)) != 1))) {
            revert TokenCallFailed();
        }
    }

    function pull(address token, address from, uint256 amount) internal {
        uint256 beforeHere = balance(token, address(this));
        uint256 beforeFrom = balance(token, from);
        call(token, abi.encodeCall(IStoreToken.transferFrom, (from, address(this), amount)));
        if (balance(token, address(this)) != beforeHere + amount || balance(token, from) + amount != beforeFrom) {
            revert InexactTransfer();
        }
    }

    function push(address token, address to, uint256 amount) internal {
        uint256 beforeHere = balance(token, address(this));
        uint256 beforeTo = balance(token, to);
        call(token, abi.encodeCall(IStoreToken.transfer, (to, amount)));
        if (balance(token, address(this)) + amount != beforeHere || balance(token, to) != beforeTo + amount) {
            revert InexactTransfer();
        }
    }
}
