// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ResultJson} from "./ResultJson.sol";

/// @dev An accepted named file is the evidence bridge. IMD hashes file bytes with SHA-256;
/// resultHash hashes the entire completion snapshot with keccak256. Workers never need to
/// inject top-level fields. The fixed approval bytes cannot contain rejected alternatives.
library AcceptedArtifact {
    using ResultJson for ResultJson.Document;

    error InvalidArtifactEvidence();

    struct Binding {
        bytes32 sourceHash;
        bytes32 sourceSubmissionHash;
        bytes32 evidenceHash;
        uint256 evidenceBytes;
    }

    struct FileExpectation {
        bytes name;
        bytes path;
        bytes32 hash;
        uint256 length;
    }

    bytes internal constant NAME = "hooksStoreApproval";
    bytes internal constant PATH = "artifacts/hooks-store-approval.json";

    function approvalDocument(bytes32 digest) internal pure returns (bytes memory) {
        return bytes.concat(
            '{"schema":"hooks-store-approval-v2","hooksStoreArtifact":"0x',
            hexHash(digest),
            '","publication":"review-evidence"}'
        );
    }

    function evidenceDocument(bytes32 build, bytes32 sourceSubmission, bytes32 reviewSubmission)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            '{"schema":"hooks-store-evidence-v1","reviewedBuild":"0x',
            hexHash(build),
            '","sourceSubmission":"0x',
            hexHash(sourceSubmission),
            '","reviewSubmission":"0x',
            hexHash(reviewSubmission),
            '"}'
        );
    }

    function verify(bytes memory snapshot, bytes32 digest, Binding memory binding) internal pure returns (bool) {
        ResultJson.Document memory d = ResultJson.parse(snapshot);
        uint256 job = d.member(0, "jobId");
        _uuid(d, job);
        uint256 complete = d.member(0, "complete");
        if (d.tokens[complete].kind != "t" || !d.eq(complete, "true") || !d.stringEq(d.member(0, "state"), "completed"))
        {
            revert InvalidArtifactEvidence();
        }
        bool sourceMatches = _source(d, binding.sourceHash, binding.sourceSubmissionHash);
        bytes memory approval = approvalDocument(digest);
        (bool approvalMatches, bytes32 publisher) =
            _file(d, FileExpectation(NAME, PATH, sha256(approval), approval.length));
        (bool evidenceMatches, bytes32 evidencePublisher) = _file(
            d,
            FileExpectation(
                "hooksStoreEvidence", "artifacts/hooks-store-evidence.json", binding.evidenceHash, binding.evidenceBytes
            )
        );
        return approvalMatches && evidenceMatches && sourceMatches && publisher == evidencePublisher;
    }

    function _uuid(ResultJson.Document memory d, uint256 token) private pure {
        ResultJson.Token memory t = d.tokens[token];
        if (t.kind != '"' || t.end - t.start != 36) revert InvalidArtifactEvidence();
        for (uint256 i; i < 36; ++i) {
            bytes1 c = d.data[t.start + i];
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                if (c != "-") revert InvalidArtifactEvidence();
            } else if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "f"))) {
                revert InvalidArtifactEvidence();
            }
        }
    }

    function _source(ResultJson.Document memory d, bytes32 sourceHash, bytes32 sourceSubmissionHash)
        private
        pure
        returns (bool)
    {
        uint256 array = d.member(0, "source");
        if (d.tokens[array].kind != "[") revert InvalidArtifactEvidence();
        uint256 cursor = array + 1;
        uint256 found;
        bytes32 sourceTextHash = keccak256(hexHash(sourceHash));
        for (uint256 i; i < d.tokens[array].size; ++i) {
            if (d.hashEq(d.tryMember(cursor, "hash"), sourceTextHash)) {
                if (
                    d.hashValue(d.member(cursor, "hash")) != sourceHash || sourceSubmissionHash == bytes32(0)
                        || d.hashValue(d.member(cursor, "submissionHash")) != sourceSubmissionHash
                ) revert InvalidArtifactEvidence();
                ++found;
            }
            cursor = d.tokens[cursor].next;
        }
        if (found > 1) revert InvalidArtifactEvidence();
        return found == 1 && sourceHash != bytes32(0);
    }

    function _file(ResultJson.Document memory d, FileExpectation memory expected)
        private
        pure
        returns (bool matches, bytes32 publisher)
    {
        uint256 array = d.member(0, "files");
        if (d.tokens[array].kind != "[") revert InvalidArtifactEvidence();
        uint256 cursor = array + 1;
        uint256 found;
        for (uint256 i; i < d.tokens[array].size; ++i) {
            bool name = d.stringEq(d.tryMember(cursor, "name"), expected.name);
            bool path = d.stringEq(d.tryMember(cursor, "path"), expected.path);
            if (name || path) {
                if (!name || !path || ++found != 1) revert InvalidArtifactEvidence();
                if (
                    !d.stringEq(d.member(cursor, "mediaType"), "application/json")
                        || d.uintValue(d.member(cursor, "bytes")) != expected.length
                        || d.hashValue(d.member(cursor, "submissionHash")) == bytes32(0)
                ) {
                    revert InvalidArtifactEvidence();
                }
                publisher = d.hashValue(d.member(cursor, "submissionHash"));
                matches = d.hashValue(d.member(cursor, "hash")) == expected.hash;
            }
            cursor = d.tokens[cursor].next;
        }
        if (found != 1) revert InvalidArtifactEvidence();
    }

    function hexHash(bytes32 value) internal pure returns (bytes memory out) {
        bytes16 digits = "0123456789abcdef";
        out = new bytes(64);
        for (uint256 i; i < 32; ++i) {
            out[2 * i] = digits[uint8(value[i]) >> 4];
            out[2 * i + 1] = digits[uint8(value[i]) & 0x0f];
        }
    }
}
