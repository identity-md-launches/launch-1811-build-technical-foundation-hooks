// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GatedHookDeployerTest} from "./GatedHookDeployer.t.sol";
import {AcceptedArtifactTest} from "./AcceptedArtifact.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {GatedHookDeployer} from "../src/deployment/GatedHookDeployer.sol";
import {AcceptedArtifact} from "../src/deployment/AcceptedArtifact.sol";
import {ResultJson} from "../src/deployment/ResultJson.sol";
import {GeneratedHook} from "./helpers/GeneratedHooks.sol";

contract ConsolidatedSecurityTest is GatedHookDeployerTest {
    function testFuzzOnlyRevokedEpochAllowsFinalizedRecovery(bool receiptFirst, bool passed) public {
        Case memory c = _generic(FLAGS);
        vm.prank(creator);
        bytes32 ask = requester.requestReview(c.jobId, PRICE);
        if (!receiptFirst) _bind(ask);
        OracleAttestation.Attestation memory a = _attestation(ask, passed);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        if (receiptFirst) _bind(ask);
        bytes32 receiptHash = requester.reviewReceiptHash(ask);
        uint64 verifiedAt = requester.reviewVerifiedAt(ask);
        vm.prank(creator);
        vm.expectRevert(bytes4(keccak256("NotOwner()")));
        requester.closeRevokedVerdict(c.jobId);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochNotRevoked.selector, uint32(1)));
        requester.closeRevokedVerdict(c.jobId);
        requester.setOracleSigner(signer);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochNotRevoked.selector, uint32(1)));
        requester.closeRevokedVerdict(c.jobId);
        requester.revokeSignerEpoch(1, keccak256("confirmed epoch incident"));
        requester.closeRevokedVerdict(c.jobId);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, c.jobId));
        requester.closeRevokedVerdict(c.jobId);
        vm.stopPrank();
        assertEq(requester.reviewReceiptHash(ask), receiptHash);
        assertEq(requester.reviewVerifiedAt(ask), verifiedAt);
        assertEq(requester.reviewReceiptSignerEpoch(ask), 1);
        assertTrue(requester.consumed(a.requestId));
        assertTrue(requester.usedIntakeRequestIds(ask));
        assertTrue(requester.revokedReviewReceipts(ask));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
        bytes32 fresh = _pass(c.jobId, true);
        assertTrue(ask != fresh);
        assertEq(requester.reviewReceiptSignerEpoch(fresh), 2);
        assertEq(_deploy(c), c.hook);
    }

    function testRecoveryCannotReuseAnAlreadyDeployedJob() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        _deploy(c);
        bytes32 digest = deployer.artifactDigest(c.a);
        vm.startPrank(owner);
        requester.setOracleSigner(signer);
        requester.revokeSignerEpoch(1, keccak256("incident"));
        requester.closeRevokedVerdict(c.jobId);
        vm.stopPrank();
        _pass(c.jobId, true);
        assertTrue(deployer.usedArtifact(digest));
        assertEq(deployer.artifactOf(c.hook), digest);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.AlreadyDeployed.selector, c.jobId, c.hook));
    }

    function testDelayedPositiveBindingPreservesHistoryAndRequiresFreshReview() public {
        Case memory c = _generic(FLAGS);
        vm.prank(creator);
        bytes32 ask = requester.requestReview(c.jobId, PRICE);
        OracleAttestation.Attestation memory a = _attestation(ask, true);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        uint64 verifiedAt = requester.reviewVerifiedAt(ask);
        vm.warp(uint256(verifiedAt) + 30 days + 1);
        _bind(ask);
        assertEq(requester.reviewVerifiedAt(ask), verifiedAt);
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertTrue(requester.consumed(a.requestId));
        assertTrue(requester.getReviewReceipt(ask).passed);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
        _pass(c.jobId, true);
        assertEq(_deploy(c), c.hook);
    }

    function testFuzzLateJobHasFullMinimumWindow(bool receiptFirst) public {
        bytes32 job = _open();
        vm.warp(block.timestamp + 180 days);
        vm.prank(creator);
        requester.expireJob(job);
        Case memory c;
        c.jobId = job;
        c.code = type(GeneratedHook).creationCode;
        c.args = abi.encode(address(manager), FLAGS);
        c.a = _artifact(job, c.code, c.args, keccak256(type(GeneratedHook).runtimeCode), FLAGS);
        c.doc = _doc(c.a);
        assertTrue(intake.complete(job, abi.encode(job, keccak256(c.doc), "ipfs://late")));
        vm.prank(owner);
        deployer.setMaxJobAge(1 days);
        bytes32 ask = receiptFirst ? _passReceiptFirst(job) : _pass(job, true);
        uint64 verifiedAt = requester.reviewVerifiedAt(ask);
        (c.salt, c.hook) = _mine(bytes.concat(c.code, c.args), FLAGS);
        vm.warp(uint256(verifiedAt) + 1 days);
        deployer.check(c.a, c.doc, c.code, c.args, c.salt, creator);
        vm.warp(block.timestamp + 1);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ApprovalStale.selector, verifiedAt, 1 days));
    }

    function testLatestPositiveBindingLeavesOneHourUnderMinimumAgePolicy() public {
        Case memory c = _generic(FLAGS);
        vm.prank(owner);
        deployer.setMaxJobAge(1 days);
        vm.prank(creator);
        bytes32 ask = requester.requestReview(c.jobId, PRICE);
        OracleAttestation.Attestation memory a = _attestation(ask, true);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        uint64 verifiedAt = requester.reviewVerifiedAt(ask);
        vm.warp(uint256(verifiedAt) + 23 hours);
        _bind(ask);
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        vm.warp(block.timestamp + 1 hours);
        assertEq(_deploy(c), c.hook);
    }

    function testOldNegativeReceiptStillFinalizesAndCannotBeShopped() public {
        Case memory c = _generic(FLAGS);
        vm.prank(creator);
        bytes32 ask = requester.requestReview(c.jobId, PRICE);
        OracleAttestation.Attestation memory a = _attestation(ask, false);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        vm.warp(block.timestamp + 365 days);
        _bind(ask);
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, c.jobId));
        requester.requestReview(c.jobId, PRICE);
    }

    function testFuzzEveryReviewIdentityFieldIsBound(uint8 field) public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        field = uint8(bound(field, 0, 3));
        if (field == 0) c.a.sourceSubmissionHash = sha256("other accepted source submission");
        if (field == 1) c.a.reviewSubmissionHash = sha256("another review");
        if (field == 2) c.a.evidenceHash = sha256("another evidence file");
        if (field == 3) c.a.buildHash = keccak256("another compiler build");
        vm.prank(creator);
        vm.expectRevert();
        deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    function testWorkerPublicationAloneCannotApprove() public {
        Case memory c = _generic(FLAGS);
        assertTrue(bytes(deployer.approvalDocument(c.a)).length != 0);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
        assertFalse(deployer.automaticBindingSupported());
    }
}

contract JsonSecurityTest is AcceptedArtifactTest {
    function testDecodedAliasesAreRejectedAtEveryDepth() public {
        bytes[4] memory cases = [
            bytes('{"x":1,"\\u0078":2}'),
            bytes(unicode'{"é":1,"\\u00e9":2}'),
            bytes('{"files":[{"name":"a","na\\u006de":"b"}]}'),
            bytes('{"x":{"a":1,"\\u0061":2}}')
        ];
        for (uint256 i; i < cases.length; ++i) {
            vm.expectRevert(ResultJson.InvalidResultJSON.selector);
            harness.parse(cases[i]);
        }
    }

    function testEscapedSelectorsAndHashesKeepExactSelection() public view {
        bytes memory raw = _snapshot(_source(), _file(DIGEST), "");
        raw = bytes(vm.replace(string(raw), '"files"', '"fi\\u006ces"'));
        raw = bytes(vm.replace(string(raw), '"hooksStoreApproval"', '"hooksStore\\u0041pproval"'));
        raw = bytes(
            vm.replace(string(raw), "artifacts/hooks-store-approval.json", "artifacts\\/hooks-store-approval.json")
        );
        bytes32 original = keccak256(raw);
        assertTrue(harness.verify(raw, DIGEST, SOURCE));
        assertEq(keccak256(raw), original, "parsing must not change the exact snapshot bytes");
    }

    function testMalformedUtf8AndEscapesRefuse() public {
        bytes[12] memory bad = [
            bytes(hex"80"),
            bytes(hex"c080"),
            bytes(hex"eda080"),
            bytes(hex"f4908080"),
            bytes(hex"f5808080"),
            bytes(hex"e282"),
            bytes(hex"c241"),
            bytes("\\x41"),
            bytes("\\uD800"),
            bytes("\\uDC00"),
            bytes("\\uD800\\u0041"),
            bytes("\\uZZZZ")
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ResultJson.InvalidResultJSON.selector);
            harness.parse(bytes.concat('{"x":"', bad[i], '"}'));
        }
    }

    function testFuzzUnicodeScalarsRoundTrip(uint32 cp) public view {
        cp = uint32(bound(cp, 0, 0x10ffff));
        vm.assume(cp < 0xd800 || cp > 0xdfff);
        bytes memory encoded;
        if (cp < 0x10000) {
            encoded = bytes.concat("\\u", _hex4(cp));
        } else {
            uint32 x = cp - 0x10000;
            encoded = bytes.concat("\\u", _hex4(0xd800 + (x >> 10)), "\\u", _hex4(0xdc00 + (x & 1023)));
        }
        harness.parse(bytes.concat('{"x":"', encoded, '"}'));
    }

    function _hex4(uint32 cp) private pure returns (bytes memory out) {
        out = new bytes(4);
        bytes16 digits = "0123456789abcdef";
        for (uint256 i; i < 4; ++i) {
            out[3 - i] = digits[(cp >> (4 * i)) & 15];
        }
    }

    function testFuzzSourceHashProbeAndCaseAliases(bytes32 source) public {
        vm.assume(source != bytes32(0));
        bytes memory h = AcceptedArtifact.hexHash(source);
        bytes memory entry =
            bytes.concat('{"hash":"', h, '","submissionHash":"', AcceptedArtifact.hexHash(SUBMISSION), '"}');
        assertTrue(harness.verify(_snapshot(entry, _file(DIGEST), ""), DIGEST, source));
        for (uint256 i; i < h.length; ++i) {
            if (h[i] >= "a" && h[i] <= "f") {
                h[i] = bytes1(uint8(h[i]) - 32);
                bytes memory aliasEntry =
                    bytes.concat('{"hash":"', h, '","submissionHash":"', AcceptedArtifact.hexHash(SUBMISSION), '"}');
                bytes memory raw = _snapshot(bytes.concat(entry, ",", aliasEntry), _file(DIGEST), "");
                vm.expectRevert(ResultJson.InvalidResultJSON.selector);
                harness.verify(raw, DIGEST, source);
                return;
            }
        }
    }

    function testEscapedControlBytesAreIrrelevantRatherThanHexAliases() public {
        bytes32 source = 0x1111111111111111111111111111111111111111111111111111111111111111;
        bytes memory controls;
        for (uint256 i; i < 64; ++i) {
            controls = bytes.concat(controls, "\\u0011");
        }
        bytes memory entries = bytes.concat(
            '{"hash":"',
            AcceptedArtifact.hexHash(source),
            '","submissionHash":"',
            AcceptedArtifact.hexHash(SUBMISSION),
            '"},{"hash":"',
            controls,
            '"}'
        );
        assertTrue(harness.verify(_snapshot(entries, _file(DIGEST), ""), DIGEST, source));
    }

    function testSourceIdentityAndEvidencePublisherMustMatch() public {
        bytes memory raw = _snapshot(_source(), _file(DIGEST), "");
        string memory wrong = string(AcceptedArtifact.hexHash(sha256("other submission")));
        bytes memory bad = bytes(vm.replace(string(raw), string(AcceptedArtifact.hexHash(SUBMISSION)), wrong));
        vm.expectRevert(AcceptedArtifact.InvalidArtifactEvidence.selector);
        harness.verify(bad, DIGEST, SOURCE);
        // Only the evidence publisher is changed; approval and source stay untouched.
        bytes memory extra = _snapshot(_source(), _file(DIGEST), "");
        string memory needle = string(
            bytes.concat(
                '"bytes":13,"hash":"',
                AcceptedArtifact.hexHash(sha256("test evidence")),
                '","submissionHash":"',
                AcceptedArtifact.hexHash(SUBMISSION)
            )
        );
        string memory replacement = string(
            bytes.concat(
                '"bytes":13,"hash":"',
                AcceptedArtifact.hexHash(sha256("test evidence")),
                '","submissionHash":"',
                bytes(wrong)
            )
        );
        assertFalse(harness.verify(bytes(vm.replace(string(extra), needle, replacement)), DIGEST, SOURCE));
    }
}
