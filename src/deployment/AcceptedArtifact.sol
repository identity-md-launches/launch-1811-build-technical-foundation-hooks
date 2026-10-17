// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ResultJson} from "./ResultJson.sol";

/// @dev An accepted named file is the evidence bridge. IMD hashes file bytes with SHA-256;
/// resultHash hashes the entire completion snapshot with keccak256. Workers never need to
/// inject top-level fields. The fixed approval bytes cannot contain rejected alternatives.
library AcceptedArtifact {
    using ResultJson for ResultJson.Document;

    error InvalidArtifactEvidence();

    bytes internal constant NAME = "hooksStoreApproval";
    bytes internal constant PATH = "artifacts/hooks-store-approval.json";

    function approvalDocument(bytes32 digest) internal pure returns (bytes memory) {
        return bytes.concat(
            '{"schema":"hooks-store-approval-v1","hooksStoreArtifact":"0x', hexHash(digest), '","review":"passed"}'
        );
    }

    function verify(bytes memory snapshot, bytes32 digest, bytes32 sourceHash) internal pure returns (bool) {
        ResultJson.Document memory d = ResultJson.parse(snapshot);
        uint256 job = d.member(0, "jobId");
        _uuid(d, job);
        uint256 complete = d.member(0, "complete");
        if (d.tokens[complete].kind != "t" || !d.eq(complete, "true") || !d.stringEq(d.member(0, "state"), "completed"))
        {
            revert InvalidArtifactEvidence();
        }
        bool sourceMatches = _source(d, sourceHash);
        bytes memory approval = approvalDocument(digest);
        return _approval(d, sha256(approval), approval.length) && sourceMatches;
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

    function _source(ResultJson.Document memory d, bytes32 sourceHash) private pure returns (bool) {
        uint256 array = d.member(0, "source");
        if (d.tokens[array].kind != "[") revert InvalidArtifactEvidence();
        uint256 cursor = array + 1;
        uint256 found;
        for (uint256 i; i < d.tokens[array].size; ++i) {
            if (d.hashValue(d.member(cursor, "hash")) == sourceHash) {
                if (d.hashValue(d.member(cursor, "submissionHash")) == bytes32(0)) revert InvalidArtifactEvidence();
                ++found;
            }
            cursor = d.tokens[cursor].next;
        }
        if (found > 1) revert InvalidArtifactEvidence();
        return found == 1 && sourceHash != bytes32(0);
    }

    function _approval(ResultJson.Document memory d, bytes32 expectedHash, uint256 expectedBytes)
        private
        pure
        returns (bool matches)
    {
        uint256 array = d.member(0, "files");
        if (d.tokens[array].kind != "[") revert InvalidArtifactEvidence();
        uint256 cursor = array + 1;
        uint256 found;
        for (uint256 i; i < d.tokens[array].size; ++i) {
            bool name = d.stringEq(d.member(cursor, "name"), NAME);
            bool path = d.stringEq(d.member(cursor, "path"), PATH);
            if (name || path) {
                if (!name || !path || ++found != 1) revert InvalidArtifactEvidence();
                if (
                    !d.stringEq(d.member(cursor, "mediaType"), "application/json")
                        || d.uintValue(d.member(cursor, "bytes")) != expectedBytes
                        || d.hashValue(d.member(cursor, "submissionHash")) == bytes32(0)
                ) {
                    revert InvalidArtifactEvidence();
                }
                matches = d.hashValue(d.member(cursor, "hash")) == expectedHash;
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
