// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequester} from "../../src/imd/HookJobRequester.sol";

/// @dev LOCAL tool-test stand-in exposing only the reads GatedHookDeployer makes. It has no oracle
/// verification: Foundry tests use the real HookJobRequester; this only drives the Python CLI on Anvil.
contract MockVerdictRequester {
    bool public automaticBindingSupported;
    mapping(bytes32 => bytes32) public approvedArtifact;

    function setAutomaticApproval(bytes32 jobId, bytes32 digest) external {
        automaticBindingSupported = true;
        approvedArtifact[jobId] = digest;
    }
    mapping(bytes32 => HookJobRequester.Job) internal jobs;
    mapping(bytes32 => bool) public revokedReviewReceipts;
    mapping(uint32 => bytes32) public revokedSignerEpochs;

    function setJob(bytes32 id, address requester, uint8 status, uint8 review, bytes32 resultHash) external {
        HookJobRequester.Job storage j = jobs[id];
        j.requester = requester;
        j.openedAt = uint64(block.timestamp);
        j.status = HookJobRequester.JobStatus(status);
        j.review = HookJobRequester.ReviewStatus(review);
        j.resultHash = resultHash;
    }

    function getJob(bytes32 id) external view returns (HookJobRequester.Job memory) {
        return jobs[id];
    }

    function reviewVerifiedAt(bytes32) external view returns (uint64) {
        return uint64(block.timestamp);
    }

    function reviewReceiptSignerEpoch(bytes32) external pure returns (uint32) {
        return 1;
    }
}
