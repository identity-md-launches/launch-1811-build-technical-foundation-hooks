// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Adversarial token used only in local tests; never part of a deployment.
contract StoreTokenMock {
    enum Mode {
        Good,
        FalseReturn,
        RevertCall,
        NoReturn,
        ShortReturn,
        NonBoolean,
        RecipientFee,
        SenderFee,
        NoMovement
    }

    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Mode public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackCount;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (mode == Mode.RevertCall) revert("mock transfer refused");
        if (mode != Mode.NoMovement) {
            balanceOf[from] -= amount + (mode == Mode.SenderFee ? 1 : 0);
            balanceOf[to] += amount - (mode == Mode.RecipientFee ? 1 : 0);
        }
        if (callbackTarget != address(0)) {
            ++callbackCount;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == Mode.NonBoolean) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode != Mode.FalseReturn;
    }
}
