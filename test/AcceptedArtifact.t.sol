// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AcceptedArtifact} from "../src/deployment/AcceptedArtifact.sol";
import {ResultJson} from "../src/deployment/ResultJson.sol";

contract AcceptedArtifactHarness {
    function verify(bytes memory snapshot, bytes32 digest, bytes32 sourceHash) external pure returns (bool) {
        return AcceptedArtifact.verify(
            snapshot,
            digest,
            AcceptedArtifact.Binding(sourceHash, sha256("accepted submission"), sha256("test evidence"), 13)
        );
    }

    function parse(bytes memory snapshot) external pure {
        ResultJson.parse(snapshot);
    }
}

contract AcceptedArtifactTest is Test {
    AcceptedArtifactHarness internal harness = new AcceptedArtifactHarness();
    bytes32 internal constant DIGEST = keccak256("approved artifact A");
    // SHA-256("accepted source bytes"), fixed to avoid a precompile consuming expectRevert.
    bytes32 internal constant SOURCE = 0xac68c35dbea2d3f0509c2fe73e3f5c37ed4d50d45de7abd466c253a6fbcdd2d8;
    bytes32 internal constant SUBMISSION = sha256("accepted submission");

    function _source() internal pure returns (bytes memory) {
        return bytes.concat(
            '{"hash":"',
            AcceptedArtifact.hexHash(SOURCE),
            '","submissionHash":"',
            AcceptedArtifact.hexHash(SUBMISSION),
            '"}'
        );
    }

    function _file(bytes32 digest) internal view returns (bytes memory) {
        bytes memory doc = AcceptedArtifact.approvalDocument(digest);
        return bytes.concat(
            '{"name":"hooksStoreApproval","path":"artifacts/hooks-store-approval.json","mediaType":"application/json","bytes":',
            bytes(vm.toString(doc.length)),
            ',"hash":"',
            AcceptedArtifact.hexHash(sha256(doc)),
            '","submissionHash":"',
            AcceptedArtifact.hexHash(SUBMISSION),
            '"}'
        );
    }

    function _snapshot(bytes memory source, bytes memory files, bytes memory extra)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            '{"jobId":"d8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9","state":"completed","complete":true,"source":[',
            source,
            '],"files":[',
            files,
            files.length == 0 ? bytes("") : bytes(","),
            '{"name":"hooksStoreEvidence","path":"artifacts/hooks-store-evidence.json","mediaType":"application/json","bytes":13,"hash":"',
            AcceptedArtifact.hexHash(sha256("test evidence")),
            '","submissionHash":"',
            AcceptedArtifact.hexHash(SUBMISSION),
            '"}]',
            extra,
            "}"
        );
    }

    function testOnlyUniqueTopLevelAcceptedFileAuthorizesArtifact() public view {
        bytes32 rejected = keccak256("rejected artifact B");
        bytes memory snapshot = _snapshot(
            _source(),
            _file(DIGEST),
            bytes.concat(
                ',"rejected":{"files":[',
                _file(rejected),
                ']},"hooksStoreArtifact":"0x',
                AcceptedArtifact.hexHash(DIGEST),
                '"'
            )
        );
        assertTrue(harness.verify(snapshot, DIGEST, SOURCE));
        assertFalse(harness.verify(snapshot, rejected, SOURCE));
    }

    function testRejectedOnlyAndDuplicateFileEntriesFailClosed() public {
        bytes memory f = _file(DIGEST);
        bytes memory nested = _snapshot(_source(), "", bytes.concat(',"rejected":{"files":[', f, "]}"));
        bytes memory duplicate = _snapshot(_source(), bytes.concat(f, ",", f), "");
        vm.expectRevert(AcceptedArtifact.InvalidArtifactEvidence.selector);
        harness.verify(nested, DIGEST, SOURCE);
        vm.expectRevert(AcceptedArtifact.InvalidArtifactEvidence.selector);
        harness.verify(duplicate, DIGEST, SOURCE);
    }

    function testDuplicateKeysAnywhereAndEscapedAliasesFailClosed() public {
        bytes[4] memory extras = [
            bytes(',"files":[]'),
            bytes(',"complete":true'),
            bytes(',"rejected":{"hash":"a","hash":"b"}'),
            bytes(',"fi\\u006ces":[]')
        ];
        for (uint256 i; i < extras.length; ++i) {
            bytes memory snapshot = _snapshot(_source(), _file(DIGEST), extras[i]);
            vm.expectRevert(ResultJson.InvalidResultJSON.selector);
            harness.verify(snapshot, DIGEST, SOURCE);
        }
    }

    function testCanonicalApprovalHasNoAmbiguousFieldsOrTrailingBytes() public view {
        bytes memory expected = bytes.concat(
            '{"schema":"hooks-store-approval-v2","hooksStoreArtifact":"0x',
            AcceptedArtifact.hexHash(DIGEST),
            '","publication":"review-evidence"}'
        );
        assertEq(AcceptedArtifact.approvalDocument(DIGEST), expected);
        assertTrue(sha256(expected) != sha256(bytes.concat(expected, "\n")));
    }

    function testSourceMustBeAcceptedAndUnambiguous() public {
        assertFalse(harness.verify(_snapshot(_source(), _file(DIGEST), ""), DIGEST, sha256("different source")));
        bytes memory duplicate = _snapshot(bytes.concat(_source(), ",", _source()), _file(DIGEST), "");
        vm.expectRevert(AcceptedArtifact.InvalidArtifactEvidence.selector);
        harness.verify(duplicate, DIGEST, SOURCE);
        assertFalse(
            harness.verify(
                _snapshot("", _file(DIGEST), bytes.concat(',"rejected":{"source":[', _source(), "]}")), DIGEST, SOURCE
            )
        );
    }

    function testWhitespaceAndReorderedMembersPreserveExactFileBinding() public view {
        bytes memory snapshot = bytes.concat(_snapshot(_source(), _file(DIGEST), ""), "\n");
        assertTrue(harness.verify(snapshot, DIGEST, SOURCE));
    }

    function testMalformedJsonAndBoundsRefuseInsteadOfGuessing() public {
        bytes[13] memory bad = [
            bytes("{}{}"),
            bytes('{"x":1,}'),
            bytes('{"x":[1,]}'),
            bytes('{"x":01}'),
            bytes('{"x":1.}'),
            bytes('{"x":1e}'),
            bytes('{"x":NaN}'),
            bytes('{"x":tru}'),
            bytes('{"x":"unterminated}'),
            bytes('{"x":"line\nbreak"}'),
            bytes('{"x":"\\uD800"}'),
            bytes("[]"),
            bytes('{"x":true false}')
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ResultJson.InvalidResultJSON.selector);
            harness.parse(bad[i]);
        }
        bytes memory deep = "0";
        for (uint256 i; i < 17; ++i) {
            deep = bytes.concat("[", deep, "]");
        }
        vm.expectRevert(ResultJson.InvalidResultJSON.selector);
        harness.parse(bytes.concat('{"x":', deep, "}"));
        bytes memory many = "0";
        for (uint256 i; i < 128; ++i) {
            many = bytes.concat(many, ",0");
        }
        vm.expectRevert(ResultJson.ResultContainerLimit.selector);
        harness.parse(bytes.concat('{"x":[', many, "]}"));
    }

    function testCompletionFlagsAndApprovalMetadataCannotBeCoerced() public {
        string memory good = string(_snapshot(_source(), _file(DIGEST), ""));
        string[9] memory beforeText = [
            string('"complete":true'),
            '"complete":true',
            '"state":"completed"',
            '"bytes":158',
            '"bytes":158',
            '"mediaType":"application/json"',
            '"name":"hooksStoreApproval"',
            '"path":"artifacts/hooks-store-approval.json"',
            "d8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9"
        ];
        string[9] memory afterText = [
            string('"complete":"true"'),
            '"complete":false',
            '"state":"pending"',
            '"bytes":158.0',
            '"bytes":157',
            '"mediaType":"text/plain"',
            '"name":"rejected"',
            '"path":"artifacts/rejected.json"',
            "z8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9"
        ];
        for (uint256 i; i < beforeText.length; ++i) {
            bytes memory bad = bytes(vm.replace(good, beforeText[i], afterText[i]));
            vm.expectRevert();
            harness.verify(bad, DIGEST, SOURCE);
        }
    }

    function testFuzzDifferentArtifactOrSourceCannotMatch(bytes32 other, bool changeSource) public view {
        bytes memory snapshot = _snapshot(_source(), _file(DIGEST), "");
        if (changeSource) {
            vm.assume(other != SOURCE);
            assertFalse(harness.verify(snapshot, DIGEST, other));
        } else {
            vm.assume(other != DIGEST);
            assertFalse(harness.verify(snapshot, other, SOURCE));
        }
    }
}
