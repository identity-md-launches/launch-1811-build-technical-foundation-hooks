// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Explicit launch owner and two-step rotation; no implicit deployer privileges.
abstract contract StoreAdmin {
    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();

    event OwnershipTransferStarted(address indexed owner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed owner);

    address public owner;
    address public pendingOwner;

    constructor(address owner_) {
        if (owner_ == address(0) || owner_ == address(this)) revert InvalidAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Replaces an outstanding proposal. The current owner retains control until acceptance.
    function transferOwnership(address proposedOwner) external onlyOwner {
        if (proposedOwner == address(0) || proposedOwner == address(this)) revert InvalidAddress();
        pendingOwner = proposedOwner;
        emit OwnershipTransferStarted(owner, proposedOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        delete pendingOwner;
        emit OwnershipTransferStarted(owner, address(0));
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        delete pendingOwner;
        emit OwnershipTransferred(previousOwner, msg.sender);
    }
}
