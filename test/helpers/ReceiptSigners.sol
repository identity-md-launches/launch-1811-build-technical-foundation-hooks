// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "../../src/vendor/openzeppelin/utils/cryptography/ECDSA.sol";

/// @dev Local ERC-1271 multisigner with real ECDSA recovery, membership, per-key expiration,
/// threshold, duplicate rejection and owner-controlled revocation. Not a production wallet.
contract ThresholdReceiptSigner {
    struct KeyPolicy {
        bool enabled;
        uint256 validUntil;
    }

    mapping(address => KeyPolicy) public keys;
    uint256 public threshold;
    address public immutable owner;

    constructor(address[] memory members, uint256 threshold_) {
        owner = msg.sender;
        threshold = threshold_;
        for (uint256 i; i < members.length; ++i) {
            keys[members[i]] = KeyPolicy(true, block.timestamp + 30 days);
        }
    }

    function revoke(address member) external {
        require(msg.sender == owner, "owner only");
        keys[member].enabled = false;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        uint256 required = threshold;
        if (signature.length != required * 65) return bytes4(0xffffffff);
        address previous;
        for (uint256 i; i < required; ++i) {
            (address recovered, ECDSA.RecoverError err,) =
                ECDSA.tryRecoverCalldata(digest, signature[i * 65:(i + 1) * 65]);
            KeyPolicy storage policy = keys[recovered];
            if (
                err != ECDSA.RecoverError.NoError || recovered <= previous || !policy.enabled
                    || block.timestamp > policy.validUntil
            ) return bytes4(0xffffffff);
            previous = recovered;
        }
        return bytes4(0x1626ba7e);
    }
}

/// @dev Exact shape of the audit's gas stressor: two cold config reads, N independent cold
/// mapping reads, then canonical ECDSA verification. Separate from the realistic multisigner.
contract ColdReadReceiptSigner {
    address public key;
    uint256 public reads;
    mapping(uint256 => uint256) public policies;

    constructor(address key_, uint256 reads_) {
        key = key_;
        reads = reads_;
        for (uint256 i; i < reads_; ++i) {
            policies[i] = i + 1;
        }
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        uint256 count = reads;
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += policies[i];
        }
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == key && sum == count * (count + 1) / 2
            ? bytes4(0x1626ba7e)
            : bytes4(0xffffffff);
    }
}
